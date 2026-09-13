import 'dart:convert';

/// Wire error code for a tool call that requires a scope the calling
/// `McpPrincipal` lacks. Not one of the codes in `package:shared`'s
/// `ErrorCode` enum, which predates MCP scopes, so it lives here as a
/// plain string alongside the enum-backed codes tools also use.
const String kErrorInsufficientScope = 'insufficient_scope';

/// Wire error code for a semantically invalid tool call (e.g. an empty
/// title, a blank search query) as opposed to a malformed one. Not one of
/// the codes in `package:shared`'s `ErrorCode` enum; see
/// [kErrorInsufficientScope].
const String kErrorValidationFailed = 'validation_failed';

/// Wire error code for a write whose resolved target path collides with a
/// different note, mirroring the HTTP API's `path_conflict` (also not an
/// `ErrorCode` enum member — see [kErrorInsufficientScope]).
const String kErrorPathConflict = 'path_conflict';

/// Wire error code for an upload whose (declared or actual) size exceeds
/// the server's configured maximum, mirroring the HTTP API's `413`
/// `payload_too_large` (also not an `ErrorCode` enum member — see
/// [kErrorInsufficientScope]).
const String kErrorPayloadTooLarge = 'payload_too_large';

/// Builds a successful `tools/call` result: [payload] serialized as the
/// sole `text` content item, and again verbatim as `structuredContent`, per
/// the `mcp-server` spec's "Tool results carry text and structured content"
/// requirement.
Map<String, Object?> toolOk(Map<String, Object?> payload) => {
      'content': [
        {'type': 'text', 'text': jsonEncode(payload)},
      ],
      'structuredContent': payload,
    };

/// Builds a failed `tools/call` result — a domain failure such as
/// not-found, a version conflict, or a validation error. Domain failures
/// are reported as an ordinary JSON-RPC *result* with `isError: true`,
/// never as a JSON-RPC protocol error, so a client can distinguish "the
/// server is broken" from "the operation was refused".
///
/// [code] is the wire error code (e.g. `not_found`, [kErrorValidationFailed]
/// ); [message] defaults to [code] when omitted; [details] are merged into
/// `structuredContent` alongside `error` and `message` (e.g. `holder` for a
/// `locked` failure, `current_version`/`current_content` for a
/// `version_conflict`).
Map<String, Object?> toolFail(
  String code, {
  String? message,
  Map<String, Object?> details = const {},
}) {
  final effectiveMessage = message ?? code;
  return {
    'isError': true,
    'content': [
      {'type': 'text', 'text': '$code: $effectiveMessage'},
    ],
    'structuredContent': {
      'error': code,
      'message': effectiveMessage,
      ...details,
    },
  };
}
