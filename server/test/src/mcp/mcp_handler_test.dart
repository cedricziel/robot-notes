import 'dart:io';

import 'package:server/src/app_deps.dart';
import 'package:server/src/config.dart';
import 'package:server/src/mcp/json_rpc.dart';
import 'package:server/src/mcp/mcp_handler.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

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
    test('returns the seven tools with declared required arrays', () async {
      final response = await handler.handle(_req('tools/list'), fullAccess);
      final result = response!['result']! as Map<String, Object?>;
      final tools = result['tools']! as List<Object?>;
      expect(tools, hasLength(7));
      final byName = {
        for (final t in tools.cast<Map<String, Object?>>()) t['name']: t,
      };
      final updateSchema =
          byName['update_note']!['inputSchema']! as Map<String, Object?>;
      expect(updateSchema['required'], ['id', 'version']);
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
  });

  test('unknown method maps to -32601 and echoes the id', () async {
    final response = await handler.handle(
      _req('resources/list'),
      fullAccess,
    );
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
