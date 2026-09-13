import 'package:dart_frog/dart_frog.dart';
import 'package:meta/meta.dart';
import 'package:server/src/constant_time.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:server/src/public_url.dart';
import 'package:server/src/rest_principal.dart';
import 'package:shared/shared.dart';

const String _healthzPath = '/healthz';
const String _wsPath = '/ws';
final RegExp _onboardingPath = RegExp(r'^/invites/[^/]+/onboarding\.txt$');
final RegExp _uploadCompletionPath = RegExp(r'^/notes/file-uploads/[^/]+$');

/// Builds a Dart Frog [Middleware] that enforces a single configured bearer
/// key — or a scoped OAuth access token issued by this server's own
/// authorization server for the REST/WS resource — on every request except
/// a fixed set of unauthenticated paths (see [_isExempt]).
///
/// An accepted request always has a [RestPrincipal] provided via
/// `context.read<RestPrincipal>()`, so downstream middleware (actor
/// resolution) and handlers can tell how it authenticated.
///
/// Failure responses are JSON `{"error": "unauthorized"}` with HTTP 401,
/// except a recognized OAuth token that lacks the scope the request's
/// method requires, which is HTTP 403 `{"error": "insufficient_scope"}`.
/// The configured key is compared in constant time against the supplied
/// header value to avoid leaking it via response timing.
Middleware bearerAuth({required String configuredKey}) {
  return (handler) {
    return (context) async {
      final request = context.request;
      if (_isExempt(request)) {
        return handler(
          context.provide<RestPrincipal>(() => const RestPrincipal.exempt()),
        );
      }

      final supplied = extractBearerToken(request.headers['authorization']);
      if (supplied == null) {
        return _unauthorized();
      }
      if (constantTimeEquals(configuredKey, supplied)) {
        return handler(
          context.provide<RestPrincipal>(() => const RestPrincipal.staticKey()),
        );
      }

      final tokenStore = context.read<TokenStore>();
      final record = await tokenStore.lookupAccess(supplied);
      final restResource = publicBaseUrl(context);
      if (record == null || record.resource != restResource) {
        return _unauthorized();
      }
      final requiredScope =
          _isSafeMethod(request.method) ? 'notes:read' : 'notes:write';
      if (!record.scopes.contains(requiredScope)) {
        return _insufficientScope();
      }
      return handler(
        context.provide<RestPrincipal>(
          () => RestPrincipal.oauth(actor: record.actor, scopes: record.scopes),
        ),
      );
    };
  };
}

/// Whether [method] is a read-only (safe) HTTP method, per RFC 9110 §9.2.1
/// — the set of methods an OAuth access token can use with only
/// `notes:read`. Every other method requires `notes:write`.
bool _isSafeMethod(HttpMethod method) =>
    method == HttpMethod.get ||
    method == HttpMethod.head ||
    method == HttpMethod.options;

/// Paths exempt from the static bearer key, by method:
///
/// - `GET /healthz`
/// - `GET /otel-config` (runtime OTel export config for clients; carries at
///   most an ingest-only key, handed to any client the same way `/healthz`
///   is)
/// - `GET /ws` (the WebSocket endpoint authenticates via its in-protocol
///   `auth` envelope rather than an HTTP header, since browsers can't set
///   arbitrary headers on the upgrade request)
/// - `GET /invites/{token}/onboarding.txt` (the token itself is the
///   credential and is single-use; bearer auth would defeat the bootstrap)
/// - `PUT /notes/file-uploads/{token}` (the upload-session token is a
///   short-lived, single-use, narrowly-scoped credential in its own
///   right — a presigned-URL-style transfer — so whatever actually holds
///   the file's bytes doesn't also need the main API key; see
///   `vault-files`'s `request_upload`/`finalize_upload` requirements)
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
          path == Routes.otelConfig ||
          path == _wsPath ||
          _onboardingPath.hasMatch(path) ||
          path == Routes.wellKnownProtectedResource ||
          path == Routes.wellKnownProtectedResourceMcp ||
          path == Routes.wellKnownAuthorizationServer ||
          path == Routes.oauthAuthorize ||
          path == Routes.oauthOidcLogin ||
          path == Routes.oauthOidcCallback;
    case HttpMethod.post:
      return path == Routes.oauthRegister ||
          path == Routes.oauthAuthorize ||
          path == Routes.oauthToken ||
          path == Routes.oauthRevoke;
    case HttpMethod.put:
      return _uploadCompletionPath.hasMatch(path);
    case HttpMethod.delete:
    case HttpMethod.head:
    case HttpMethod.options:
    case HttpMethod.patch:
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

Response _insufficientScope() {
  return Response.json(
    statusCode: 403,
    body: const {'error': 'insufficient_scope'},
  );
}

/// Test-only handle on the bearer-token parser; lets the unit tests assert
/// "malformed Authorization" cases without driving a full middleware chain.
@visibleForTesting
String? debugExtractBearer(String? header) => extractBearerToken(header);
