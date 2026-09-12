import 'package:meta/meta.dart';

/// JSON-RPC 2.0 "Parse error" — the request body was not valid JSON.
const int kParseError = -32700;

/// JSON-RPC 2.0 "Invalid Request" — well-formed JSON that is not a single
/// valid JSON-RPC 2.0 message (a batch, or missing/mismatched `jsonrpc`).
const int kInvalidRequest = -32600;

/// JSON-RPC 2.0 "Method not found".
const int kMethodNotFound = -32601;

/// JSON-RPC 2.0 "Invalid params".
const int kInvalidParams = -32602;

/// JSON-RPC 2.0 "Internal error".
const int kInternalError = -32603;

/// Thrown by [JsonRpcMessage.parse] when the decoded value is not a single
/// valid JSON-RPC 2.0 message: a batch array, a non-object, or an object
/// missing `"jsonrpc":"2.0"`. The `/mcp` route maps this to HTTP 400 with
/// a JSON-RPC error whose code is [kInvalidRequest].
@immutable
class JsonRpcInvalidRequest implements Exception {
  /// Creates an invalid-request error describing why parsing failed.
  const JsonRpcInvalidRequest(this.message);

  /// Human-readable reason, suitable for the JSON-RPC error `message`.
  final String message;

  @override
  String toString() => 'JsonRpcInvalidRequest: $message';
}

/// Thrown by [JsonRpcMessage.parse] when a request — as opposed to a
/// notification, which has no reply channel to report this on — supplies
/// a `params` value that is present but not a JSON object (this server
/// only accepts by-name params). Carries the request's own [id] so the
/// `/mcp` route can reply with the standard `-32602` JSON-RPC error
/// echoing it, rather than the batch/malformed-message `-32600`
/// [JsonRpcInvalidRequest] gets.
@immutable
class JsonRpcInvalidParamsAtParse implements Exception {
  /// Creates an invalid-params error for the request identified by [id].
  const JsonRpcInvalidParamsAtParse(this.id, this.message);

  /// The request id to echo in the JSON-RPC error response.
  final Object id;

  /// Human-readable reason, suitable for the JSON-RPC error `message`.
  final String message;

  @override
  String toString() => 'JsonRpcInvalidParamsAtParse($id): $message';
}

/// A decoded JSON-RPC 2.0 message: a [JsonRpcRequest], a
/// [JsonRpcNotification], or a [JsonRpcResponse] (a reply sent *to* us by
/// the client, which this server never solicits but must still accept).
sealed class JsonRpcMessage {
  const JsonRpcMessage();

  /// Parses [decoded] — the result of `jsonDecode` on the `/mcp` request
  /// body — into one of the three message shapes. Throws
  /// [JsonRpcInvalidRequest] for arrays, non-objects, or a missing/wrong
  /// `jsonrpc` field. Throws [JsonRpcInvalidParamsAtParse] when a request
  /// (but not a notification) supplies a non-object `params`.
  factory JsonRpcMessage.parse(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      throw JsonRpcInvalidRequest(
        decoded is List
            ? 'batch requests are not supported'
            : 'message must be a JSON object',
      );
    }
    if (decoded['jsonrpc'] != '2.0') {
      throw const JsonRpcInvalidRequest(
        'missing or invalid "jsonrpc" field',
      );
    }

    final rawParams = decoded['params'];
    final paramsShapeValid =
        rawParams == null || rawParams is Map<String, Object?>;
    final params = paramsShapeValid ? rawParams as Map<String, Object?>? : null;

    final method = decoded['method'];
    final hasId = decoded.containsKey('id');
    if (method is String) {
      if (!hasId) {
        // A notification has no reply channel, so a malformed `params`
        // shape is dropped rather than failing parse.
        return JsonRpcNotification(method: method, params: params);
      }
      final id = decoded['id'];
      if (id is! int && id is! String) {
        throw const JsonRpcInvalidRequest('id must be a string or a number');
      }
      if (!paramsShapeValid) {
        throw JsonRpcInvalidParamsAtParse(id!, 'params must be an object');
      }
      return JsonRpcRequest(id: id!, method: method, params: params);
    }

    if (hasId) {
      final rawError = decoded['error'];
      if (rawError != null && rawError is! Map<String, Object?>) {
        throw const JsonRpcInvalidRequest('error must be an object');
      }
      return JsonRpcResponse(
        id: decoded['id'],
        result: decoded['result'],
        error: rawError as Map<String, Object?>?,
      );
    }

    throw const JsonRpcInvalidRequest('message has neither method nor id');
  }
}

/// A JSON-RPC request expecting a response: carries an [id] the reply must
/// echo.
@immutable
final class JsonRpcRequest extends JsonRpcMessage {
  /// Creates a request.
  const JsonRpcRequest({required this.id, required this.method, this.params});

  /// Request identifier, echoed verbatim by the response. Either an [int]
  /// or a [String] per JSON-RPC 2.0 §4.
  final Object id;

  /// The JSON-RPC method name, e.g. `initialize`, `tools/call`.
  final String method;

  /// Named parameters, or `null` when the request carried none.
  final Map<String, Object?>? params;
}

/// A JSON-RPC notification: fire-and-forget, no `id`, no reply expected.
@immutable
final class JsonRpcNotification extends JsonRpcMessage {
  /// Creates a notification.
  const JsonRpcNotification({required this.method, this.params});

  /// The JSON-RPC method name, e.g. `notifications/initialized`.
  final String method;

  /// Named parameters, or `null` when the notification carried none.
  final Map<String, Object?>? params;
}

/// A reply the *client* sends to a request this server issued. This server
/// never issues server-initiated requests, but the Streamable HTTP
/// transport still requires accepting the shape (HTTP 202, no body).
@immutable
final class JsonRpcResponse extends JsonRpcMessage {
  /// Creates a client response.
  const JsonRpcResponse({required this.id, this.result, this.error});

  /// Identifier echoing the original request.
  final Object? id;

  /// The success payload, when the client is reporting success.
  final Object? result;

  /// The JSON-RPC error object, when the client is reporting failure.
  final Map<String, Object?>? error;
}

/// Builds a JSON-RPC success response echoing [id] and wrapping [result].
Map<String, Object?> jsonRpcResult(Object? id, Object? result) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };

/// Builds a JSON-RPC error response echoing [id], with the standard
/// `code`/`message` error object plus optional [data].
Map<String, Object?> jsonRpcError(
  Object? id,
  int code,
  String message, {
  Object? data,
}) =>
    {
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    };
