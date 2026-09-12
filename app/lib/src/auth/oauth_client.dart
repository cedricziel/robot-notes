import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../config/config_store.dart';

/// Thrown by [OAuthClient.ensureRegistered] when Dynamic Client
/// Registration fails or the response is malformed.
@immutable
class OAuthClientRegistrationException implements Exception {
  /// Creates the exception wrapping a human-readable [message].
  const OAuthClientRegistrationException(this.message);

  /// Detail suitable for a log line.
  final String message;

  @override
  String toString() => 'OAuthClientRegistrationException: $message';
}

/// Generates a fresh RFC 7636 PKCE code verifier: 32 bytes of secure
/// randomness, base64url-encoded without padding (43 characters, within
/// the required 43-128 range).
String generatePkceVerifier() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Computes the RFC 7636 S256 code challenge for [verifier]: base64url
/// (no padding) of the SHA-256 digest of the verifier's UTF-8 bytes.
/// Mirrors the server's own `pkce.dart`.
String pkceS256Challenge(String verifier) {
  final digest = sha256.convert(utf8.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// The app's own OAuth client identity against a robot-notes server: it
/// registers itself once via Dynamic Client Registration (RFC 7591, the
/// same mechanism any MCP client uses) and builds authorization-code+PKCE
/// URLs for sign-in.
class OAuthClient {
  /// Creates a client backed by [store] for the registration cache and
  /// [clientFactory] for HTTP requests (a fresh client per call, closed
  /// after use).
  OAuthClient({required ConfigStore store, required this.clientFactory})
    : _store = store;

  final ConfigStore _store;

  /// Builds a fresh [http.Client] per request.
  final http.Client Function() clientFactory;

  /// Returns this app's OAuth client id for [baseUrl], registering one
  /// via `POST /oauth/register` if none is cached yet for that exact
  /// server. The registration is a public client (no secret) redirecting
  /// only to [redirectUri].
  Future<String> ensureRegistered({
    required String baseUrl,
    required String redirectUri,
  }) async {
    final cached = await _store.readRegisteredOAuthClientId(baseUrl);
    if (cached != null) return cached;

    final client = clientFactory();
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/oauth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Robot Notes',
          'redirect_uris': [redirectUri],
        }),
      );
      if (response.statusCode != 201) {
        throw OAuthClientRegistrationException(
          'Registration failed with HTTP ${response.statusCode}.',
        );
      }
      final decoded = jsonDecode(response.body);
      final clientId = decoded is Map<String, dynamic>
          ? decoded['client_id']
          : null;
      if (clientId is! String) {
        throw const OAuthClientRegistrationException(
          'Registration response had no client_id.',
        );
      }
      await _store.writeRegisteredOAuthClientId(baseUrl, clientId);
      return clientId;
    } finally {
      client.close();
    }
  }

  /// Builds the authorization-code+PKCE authorize URL for [baseUrl],
  /// requesting both scopes against the REST/WS resource (`<base>`, not
  /// `/mcp` — this app is a human session, not an agent).
  Uri buildAuthorizeUri({
    required String baseUrl,
    required String clientId,
    required String redirectUri,
    required String codeChallenge,
    required String state,
  }) {
    return Uri.parse('$baseUrl/oauth/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'scope': 'notes:read notes:write',
        'resource': baseUrl,
        'state': state,
      },
    );
  }
}
