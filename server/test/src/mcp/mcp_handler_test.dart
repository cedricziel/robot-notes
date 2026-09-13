import 'dart:convert';
import 'dart:io';

import 'package:flutter_otel_sdk/flutter_otel_sdk.dart' hide LogRecord, Logger;
import 'package:logging/logging.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/config.dart';
import 'package:server/src/mcp/json_rpc.dart';
import 'package:server/src/mcp/mcp_handler.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

class _RecordingSpanProcessor implements SpanProcessor {
  final List<SpanData> ended = [];

  @override
  void onEnd(SpanData span) => ended.add(span);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

const McpPrincipal fullAccess = McpPrincipal.staticKey('tester');

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-mcp-handler-test-');

Future<AppDeps> _bootstrap(Directory tmp) {
  final config = Config(
    apiKey: 'test-key',
    dataDir: tmp.path,
    port: 0,
    lockTtlSeconds: 60,
  );
  return AppDeps.bootstrap(config);
}

JsonRpcRequest _req(
  String method, {
  Object id = 1,
  Map<String, Object?>? params,
}) =>
    JsonRpcRequest(id: id, method: method, params: params);

void main() {
  late Directory tmp;
  late AppDeps deps;
  late McpHandler handler;

  setUp(() async {
    tmp = _tempDir();
    deps = await _bootstrap(tmp);
    handler = McpHandler(
      tools: McpToolRegistry.forDeps(deps),
      serverVersion: robotNotesVersion,
    );
  });

  tearDown(() async {
    await deps.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('initialize', () {
    test('echoes a supported protocol version', () async {
      final response = await handler.handle(
        _req('initialize', params: {'protocolVersion': '2025-11-25'}),
        fullAccess,
      );
      final result = response!['result']! as Map<String, Object?>;
      expect(result['protocolVersion'], '2025-11-25');
      expect(result['serverInfo'], {
        'name': 'robot-notes',
        'version': robotNotesVersion,
      });
      expect(result['capabilities'], {
        'tools': {'listChanged': false},
      });
      final instructions = result['instructions'];
      expect(instructions, isA<String>());
      expect((instructions! as String).isNotEmpty, isTrue);
    });

    test('falls back to the default version when unsupported', () async {
      final response = await handler.handle(
        _req('initialize', params: {'protocolVersion': '1999-01-01'}),
        fullAccess,
      );
      final result = response!['result']! as Map<String, Object?>;
      expect(result['protocolVersion'], kDefaultProtocolVersion);
    });

    test('falls back to the default version when omitted', () async {
      final response = await handler.handle(_req('initialize'), fullAccess);
      final result = response!['result']! as Map<String, Object?>;
      expect(result['protocolVersion'], kDefaultProtocolVersion);
    });
  });

  test('ping returns an empty object', () async {
    final response = await handler.handle(_req('ping'), fullAccess);
    expect(response, {
      'jsonrpc': '2.0',
      'id': 1,
      'result': <String, Object?>{},
    });
  });

  group('tools/list', () {
    test('returns the nine tools with declared required arrays', () async {
      final response = await handler.handle(_req('tools/list'), fullAccess);
      final result = response!['result']! as Map<String, Object?>;
      final tools = result['tools']! as List<Object?>;
      expect(tools, hasLength(9));
      final byName = {
        for (final t in tools.cast<Map<String, Object?>>()) t['name']: t,
      };
      final updateSchema =
          byName['update_note']!['inputSchema']! as Map<String, Object?>;
      expect(updateSchema['required'], ['id', 'version']);

      final deleteAnnotations =
          byName['delete_note']!['annotations']! as Map<String, Object?>;
      expect(deleteAnnotations['destructiveHint'], isTrue);

      final listAnnotations =
          byName['list_notes']!['annotations']! as Map<String, Object?>;
      expect(listAnnotations['readOnlyHint'], isTrue);
    });
  });

  group('tools/call', () {
    test('routes to the registry and returns its result', () async {
      final response = await handler.handle(
        _req(
          'tools/call',
          params: {
            'name': 'create_note',
            'arguments': {'title': 'From handler'},
          },
        ),
        fullAccess,
      );
      final result = response!['result']! as Map<String, Object?>;
      final structured = result['structuredContent']! as Map<String, Object?>;
      expect(structured['title'], 'From handler');
    });

    test('defaults arguments to an empty object', () async {
      final response = await handler.handle(
        _req('tools/call', params: {'name': 'list_notes'}),
        fullAccess,
      );
      final result = response!['result']! as Map<String, Object?>;
      expect(result['structuredContent'], isNotNull);
    });

    test('unknown tool maps to -32602', () async {
      final response = await handler.handle(
        _req('tools/call', params: {'name': 'no_such_tool'}),
        fullAccess,
      );
      final error = response!['error']! as Map<String, Object?>;
      expect(error['code'], kInvalidParams);
    });

    test('missing params.name maps to -32602', () async {
      final response = await handler.handle(_req('tools/call'), fullAccess);
      final error = response!['error']! as Map<String, Object?>;
      expect(error['code'], kInvalidParams);
    });

    test(
      'a tool that throws maps to a generic -32603 without leaking details',
      () async {
        final boomHandler = McpHandler(
          tools: McpToolRegistry([
            McpTool(
              name: 'boom',
              description: 'throws for the test',
              inputSchema: const {
                'type': 'object',
                'properties': <String, Object?>{},
                'required': <String>[],
              },
              annotations: const {'title': 'Boom'},
              requiresWrite: false,
              handler: (args, principal) async {
                throw StateError('/secret/data/path leaked');
              },
            ),
          ]),
          serverVersion: robotNotesVersion,
        );

        final response = await boomHandler.handle(
          _req('tools/call', params: {'name': 'boom'}),
          fullAccess,
        );
        final error = response!['error']! as Map<String, Object?>;
        expect(error['code'], kInternalError);
        expect(error['message'], 'Internal error');
        expect(jsonEncode(response), isNot(contains('/secret/data/path')));
      },
    );
  });

  group('tools/call tracing and logging', () {
    ({_RecordingSpanProcessor processor, McpHandler handler}) tracedHandler() {
      final processor = _RecordingSpanProcessor();
      final tracer = SdkTracer(
        name: 'test',
        version: null,
        processor: processor,
      );
      return (
        processor: processor,
        handler: McpHandler(
          tools: McpToolRegistry.forDeps(deps),
          serverVersion: robotNotesVersion,
          tracer: tracer,
        ),
      );
    }

    ({List<LogRecord> records, McpHandler handler}) loggedHandler() {
      hierarchicalLoggingEnabled = true;
      final logger = Logger('mcp_handler')..level = Level.ALL;
      final records = <LogRecord>[];
      final sub = logger.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      return (
        records: records,
        handler: McpHandler(
          tools: McpToolRegistry.forDeps(deps),
          serverVersion: robotNotesVersion,
          logger: logger,
        ),
      );
    }

    test('starts a child span named mcp.tools.call naming the tool', () async {
      final h = tracedHandler();

      await h.handler.handle(
        _req(
          'tools/call',
          params: {
            'name': 'create_note',
            'arguments': {'title': 'Traced'},
          },
        ),
        fullAccess,
      );

      final span = h.processor.ended.single;
      expect(span.name, 'mcp.tools.call');
      expect(span.attributes['mcp.tool.name'], 'create_note');
      expect(span.statusCode, StatusCode.unset);
    });

    test('sets an error status on the span for an unknown tool', () async {
      final h = tracedHandler();

      await h.handler.handle(
        _req('tools/call', params: {'name': 'no_such_tool'}),
        fullAccess,
      );

      expect(h.processor.ended.single.statusCode, StatusCode.error);
    });

    test('sets an error status on the span for invalid params', () async {
      final h = tracedHandler();

      await h.handler.handle(
        _req('tools/call', params: {'name': 'get_note'}),
        fullAccess,
      );

      expect(h.processor.ended.single.statusCode, StatusCode.error);
    });

    test(
      'records the exception on the span for an unexpected tool failure',
      () async {
        final processor = _RecordingSpanProcessor();
        final tracer = SdkTracer(
          name: 'test',
          version: null,
          processor: processor,
        );
        final boomHandler = McpHandler(
          tools: McpToolRegistry([
            McpTool(
              name: 'boom',
              description: 'throws for the test',
              inputSchema: const {
                'type': 'object',
                'properties': <String, Object?>{},
                'required': <String>[],
              },
              annotations: const {'title': 'Boom'},
              requiresWrite: false,
              handler: (args, principal) async {
                throw StateError('boom');
              },
            ),
          ]),
          serverVersion: robotNotesVersion,
          tracer: tracer,
        );

        await boomHandler.handle(
          _req('tools/call', params: {'name': 'boom'}),
          fullAccess,
        );

        final span = processor.ended.single;
        expect(span.statusCode, StatusCode.error);
        expect(span.events.single.name, 'exception');
        expect(span.events.single.attributes['exception.type'], 'StateError');
      },
    );

    test('logs a warning naming the tool when it is unknown', () async {
      final h = loggedHandler();

      await h.handler.handle(
        _req('tools/call', params: {'name': 'no_such_tool'}),
        fullAccess,
      );

      expect(h.records, isNotEmpty);
      expect(h.records.single.level, Level.WARNING);
      expect(h.records.single.message, contains('no_such_tool'));
    });

    test(
      'logs a warning naming the violation when params are invalid',
      () async {
        final h = loggedHandler();

        await h.handler.handle(
          _req('tools/call', params: {'name': 'get_note'}),
          fullAccess,
        );

        expect(h.records, isNotEmpty);
        expect(h.records.single.level, Level.WARNING);
        expect(h.records.single.message, contains('id is required'));
      },
    );
  });

  test('unknown method maps to -32601 and echoes the id', () async {
    final response = await handler.handle(_req('resources/list'), fullAccess);
    final error = response!['error']! as Map<String, Object?>;
    expect(error['code'], kMethodNotFound);
    expect(response['id'], 1);
  });

  group('notifications and client responses yield no reply', () {
    test('a notification returns null', () async {
      final response = await handler.handle(
        const JsonRpcNotification(method: 'notifications/initialized'),
        fullAccess,
      );
      expect(response, isNull);
    });

    test('a client response returns null', () async {
      final response = await handler.handle(
        const JsonRpcResponse(id: 1, result: {'ok': true}),
        fullAccess,
      );
      expect(response, isNull);
    });
  });
}
