import 'package:meta/meta.dart';

/// Stable wire-format error codes shared by HTTP and WebSocket responses.
enum ErrorCode {
  unauthorized('unauthorized'),
  notFound('not_found'),
  badRequest('bad_request'),
  versionConflict('version_conflict'),
  preconditionRequired('precondition_required'),
  locked('locked'),
  emptyQuery('empty_query'),
  invalidQuery('invalid_query'),
  invalidTtl('invalid_ttl'),
  inviteNotFound('invite_not_found'),
  inviteBurned('invite_burned'),
  unknownType('unknown_type'),
  authFailed('auth_failed'),
  authTimeout('auth_timeout'),
  internalError('internal_error');

  const ErrorCode(this.wire);

  /// The on-the-wire string for this code.
  final String wire;

  /// Resolves an [ErrorCode] from its wire-format string, or `null` if the
  /// string does not name a known code.
  static ErrorCode? fromWire(String wire) {
    for (final c in ErrorCode.values) {
      if (c.wire == wire) return c;
    }
    return null;
  }
}

/// HTTP error envelope: every non-2xx response body for the v1 API has the
/// shape `{"error": "<code>", ... }` with optional `message` and additional
/// detail keys merged at the top level.
@immutable
class ErrorEnvelope {
  const ErrorEnvelope({required this.code, this.message, this.details});

  final ErrorCode code;
  final String? message;
  final Map<String, dynamic>? details;

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{'error': code.wire};
    if (message != null) out['message'] = message;
    if (details != null) out.addAll(details!);
    return out;
  }

  factory ErrorEnvelope.fromJson(Map<String, dynamic> json) {
    final wire = json['error'] as String?;
    if (wire == null) {
      throw const FormatException('Error envelope missing "error" field');
    }
    final code = ErrorCode.fromWire(wire);
    if (code == null) {
      throw FormatException('Unknown error code: $wire');
    }
    final message = json['message'] as String?;
    final details = <String, dynamic>{
      for (final entry in json.entries)
        if (entry.key != 'error' && entry.key != 'message')
          entry.key: entry.value,
    };
    return ErrorEnvelope(
      code: code,
      message: message,
      details: details.isEmpty ? null : details,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! ErrorEnvelope) return false;
    if (other.code != code) return false;
    if (other.message != message) return false;
    return _mapEquals(other.details, details);
  }

  @override
  int get hashCode => Object.hash(code, message, _mapHash(details));
}

bool _mapEquals(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    if (!b.containsKey(k)) return false;
    if (a[k] != b[k]) return false;
  }
  return true;
}

int _mapHash(Map<String, dynamic>? m) {
  if (m == null) return 0;
  var h = 0;
  for (final entry in m.entries) {
    h ^= Object.hash(entry.key, entry.value);
  }
  return h;
}
