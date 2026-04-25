import 'package:dart_frog/dart_frog.dart';
import 'package:meta/meta.dart';
import 'package:server/src/constant_time.dart';

const String _healthzPath = '/healthz';

/// Builds a Dart Frog [Middleware] that enforces a single configured bearer
/// key on every request except `GET /healthz`.
///
/// Failure responses are JSON `{"error": "unauthorized"}` with HTTP 401.
/// The configured key is compared in constant time against the supplied
/// header value to avoid leaking it via response timing.
Middleware bearerAuth({required String configuredKey}) {
  return (handler) {
    return (context) async {
      final request = context.request;
      if (_isHealthz(request)) {
        return handler(context);
      }

      final supplied = _extractBearer(request.headers['authorization']);
      if (supplied == null) {
        return _unauthorized();
      }
      if (!constantTimeEquals(configuredKey, supplied)) {
        return _unauthorized();
      }
      return handler(context);
    };
  };
}

bool _isHealthz(Request request) {
  return request.method == HttpMethod.get && request.uri.path == _healthzPath;
}

String? _extractBearer(String? header) {
  if (header == null) return null;
  final trimmed = header.trim();
  if (trimmed.isEmpty) return null;
  final spaceIdx = trimmed.indexOf(' ');
  if (spaceIdx <= 0) return null;
  final scheme = trimmed.substring(0, spaceIdx);
  if (scheme.toLowerCase() != 'bearer') return null;
  final token = trimmed.substring(spaceIdx + 1).trim();
  if (token.isEmpty) return null;
  return token;
}

Response _unauthorized() {
  return Response.json(
    statusCode: 401,
    body: const {'error': 'unauthorized'},
  );
}

/// Test-only handle on the bearer-token parser; lets the unit tests assert
/// "malformed Authorization" cases without driving a full middleware chain.
@visibleForTesting
String? debugExtractBearer(String? header) => _extractBearer(header);
