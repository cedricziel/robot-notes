import 'package:dart_frog/dart_frog.dart';
import 'package:meta/meta.dart';
import 'package:server/src/constant_time.dart';
import 'package:shared/shared.dart';

const String _healthzPath = '/healthz';
const String _wsPath = '/ws';
final RegExp _onboardingPath = RegExp(r'^/invites/[^/]+/onboarding\.txt$');

/// Builds a Dart Frog [Middleware] that enforces a single configured bearer
/// key on every request except a fixed set of unauthenticated paths (see
/// [_isExempt]).
///
/// Failure responses are JSON `{"error": "unauthorized"}` with HTTP 401.
/// The configured key is compared in constant time against the supplied
/// header value to avoid leaking it via response timing.
Middleware bearerAuth({required String configuredKey}) {
  return (handler) {
    return (context) async {
      final request = context.request;
      if (_isExempt(request)) {
        return handler(context);
      }

      final supplied = extractBearerToken(request.headers['authorization']);
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

/// Paths exempt from the static bearer key, by method:
///
/// - `GET /healthz`
/// - `GET /ws` (the WebSocket endpoint authenticates via its in-protocol
///   `auth` envelope rather than an HTTP header, since browsers can't set
///   arbitrary headers on the upgrade request)
/// - `GET /invites/{token}/onboarding.txt` (the token itself is the
///   credential and is single-use; bearer auth would defeat the bootstrap)
/// - `GET /.well-known/oauth-protected-resource`,
///   `GET /.well-known/oauth-protected-resource/mcp`, and
///   `GET /.well-known/oauth-authorization-server` (public discovery
///   documents)
/// - `GET /oauth/authorize` and `POST` on `/oauth/register`,
///   `/oauth/authorize`, `/oauth/token`, `/oauth/revoke` (OAuth endpoints
///   authenticate the client or resource owner themselves)
/// - every method on `/mcp` (a dedicated middleware installed by a later
///   PR authenticates it with either the static key or an OAuth access
///   token)
///
/// Every other path/method combination — including look-alikes such as
/// `/oauthx` or `/oauth/other` — requires the static key.
bool _isExempt(Request request) {
  final path = request.uri.path;
  if (path == Routes.mcp) return true;

  switch (request.method) {
    case HttpMethod.get:
      return path == _healthzPath ||
          path == _wsPath ||
          _onboardingPath.hasMatch(path) ||
          path == Routes.wellKnownProtectedResource ||
          path == Routes.wellKnownProtectedResourceMcp ||
          path == Routes.wellKnownAuthorizationServer ||
          path == Routes.oauthAuthorize;
    case HttpMethod.post:
      return path == Routes.oauthRegister ||
          path == Routes.oauthAuthorize ||
          path == Routes.oauthToken ||
          path == Routes.oauthRevoke;
    case HttpMethod.delete:
    case HttpMethod.head:
    case HttpMethod.options:
    case HttpMethod.patch:
    case HttpMethod.put:
      return false;
  }
}

/// Parses an `Authorization` header value, returning the bearer credential
/// when the header is a well-formed `Bearer <token>` value and `null`
/// otherwise (missing header, wrong scheme, or empty token).
///
/// Shared by [bearerAuth] and the `/mcp`-specific auth middleware
/// (`lib/src/mcp/mcp_auth_middleware.dart`), which accepts the same static
/// key alongside OAuth access tokens.
String? extractBearerToken(String? header) {
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
String? debugExtractBearer(String? header) => extractBearerToken(header);
