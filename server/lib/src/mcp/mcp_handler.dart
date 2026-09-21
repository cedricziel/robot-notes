import 'package:dart_otel_api/dart_otel_api.dart' hide Logger;
import 'package:logging/logging.dart';
import 'package:server/src/mcp/json_rpc.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tools.dart';

/// MCP protocol versions this server understands, oldest first.
const List<String> kSupportedProtocolVersions = [
  '2025-03-26',
  '2025-06-18',
  '2025-11-25',
];

/// Protocol version `initialize` advertises when the client requested one
/// this server does not support.
const String kDefaultProtocolVersion = '2025-06-18';

const String _instructions =
    'Notes are shared memory between humans and agents in this workspace. '
    'Call search_notes before create_note to avoid making a duplicate of an '
    'existing note. Use append_to_note — not get_note followed by '
    'update_note — when you only need to add material to the end of an '
    'existing note; it retries automatically if another actor wrote to the '
    'note first.';

/// Dispatches parsed JSON-RPC messages to the MCP method surface
/// (`initialize`, `ping`, `tools/list`, `tools/call`). Pure: no I/O beyond
/// what [tools] performs — message in, an optional response map out. The
/// `/mcp` route (PR 5) owns everything transport-shaped: HTTP status
/// codes, headers, and decoding the request body into a [JsonRpcMessage].
class McpHandler {
  /// Creates a handler serving [tools] and advertising [serverVersion] in
  /// `initialize`'s `serverInfo`. [logger] is optional; production callers
  /// can pass a named logger so a tool's uncaught exception surfaces in a
  /// recognisable channel. [tracer] is optional; production callers pass
  /// the server's tracer so each `tools/call` gets a child span named
  /// after the tool.
  McpHandler({
    required this.tools,
    required this.serverVersion,
    Logger? logger,
    Tracer? tracer,
  })  : _log = logger ?? Logger('mcp_handler'),
        _tracer = tracer ?? const NoopTracer('mcp_handler');

  /// The note tool catalog this handler serves.
  final McpToolRegistry tools;

  /// Version string reported as `serverInfo.version` on `initialize`.
  final String serverVersion;

  final Logger _log;
  final Tracer _tracer;

  /// Handles one decoded [message] on behalf of [principal].
  ///
  /// Returns the JSON-RPC response map for a [JsonRpcRequest]. Returns
  /// `null` for a [JsonRpcNotification] or a [JsonRpcResponse] (a reply
  /// the client sent us), which carry no `id` to reply to.
  Future<Map<String, Object?>?> handle(
    JsonRpcMessage message,
    McpPrincipal principal,
  ) async {
    if (message is! JsonRpcRequest) return null;

    switch (message.method) {
      case 'initialize':
        return jsonRpcResult(message.id, _initializeResult(message.params));
      case 'ping':
        return jsonRpcResult(message.id, const <String, Object?>{});
      case 'tools/list':
        return jsonRpcResult(message.id, tools.listResult());
      case 'tools/call':
        return _handleToolsCall(message, principal);
      default:
        return jsonRpcError(
          message.id,
          kMethodNotFound,
          'Unknown method: ${message.method}',
        );
    }
  }

  Map<String, Object?> _initializeResult(Map<String, Object?>? params) {
    final requested = params?['protocolVersion'];
    final version =
        requested is String && kSupportedProtocolVersions.contains(requested)
            ? requested
            : kDefaultProtocolVersion;
    return {
      'protocolVersion': version,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {'name': 'robot-notes', 'version': serverVersion},
      'instructions': _instructions,
    };
  }

  Future<Map<String, Object?>> _handleToolsCall(
    JsonRpcRequest message,
    McpPrincipal principal,
  ) async {
    final params = message.params;
    final name = params?['name'];
    if (params == null || name is! String) {
      return jsonRpcError(
        message.id,
        kInvalidParams,
        'tools/call requires params.name',
      );
    }
    final rawArguments = params['arguments'];
    if (rawArguments != null && rawArguments is! Map<String, Object?>) {
      return jsonRpcError(
        message.id,
        kInvalidParams,
        'params.arguments must be an object',
      );
    }
    final arguments = (rawArguments as Map<String, Object?>?) ?? const {};

    return _tracer.startActiveSpan(
      'mcp.tools.call',
      attributes: {'mcp.tool.name': name},
      (span) async {
        try {
          final result = await tools.call(name, arguments, principal);
          return jsonRpcResult(message.id, result);
        } on McpUnknownToolException {
          _log.warning('tools/call "$name" — unknown tool');
          span.setStatus(StatusCode.error, description: 'unknown tool');
          return jsonRpcError(
            message.id,
            kInvalidParams,
            'Unknown tool: $name',
          );
        } on McpInvalidParamsException catch (e) {
          _log.warning('tools/call "$name" — invalid params: ${e.message}');
          span.setStatus(StatusCode.error, description: e.message);
          return jsonRpcError(message.id, kInvalidParams, e.message);
        } on Object catch (e, st) {
          _log.severe('tools/call "$name" failed', e, st);
          span
            ..recordException(e, stackTrace: st)
            ..setStatus(StatusCode.error, description: e.toString());
          return jsonRpcError(message.id, kInternalError, 'Internal error');
        }
      },
    );
  }
}
