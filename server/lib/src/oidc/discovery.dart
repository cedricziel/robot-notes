import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// Thrown by [fetchOidcDiscovery] when the issuer's discovery document
/// cannot be fetched, parsed, or is missing a required field.
@immutable
class OidcDiscoveryException implements Exception {
  /// Creates the exception wrapping a human-readable [message].
  const OidcDiscoveryException(this.message);

  /// Why discovery failed. Always names the issuer, suitable for a
  /// startup error.
  final String message;

  @override
  String toString() => 'OidcDiscoveryException: $message';
}

/// The subset of an OIDC provider's discovery document this server needs.
@immutable
class OidcDiscoveryDocument {
  /// Creates a resolved discovery document.
  const OidcDiscoveryDocument({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.jwksUri,
  });

  /// Where to redirect the user agent to start a login.
  final String authorizationEndpoint;

  /// Where to exchange an authorization code for tokens.
  final String tokenEndpoint;

  /// Where to fetch the JSON Web Key Set used to verify ID token
  /// signatures.
  final String jwksUri;
}

/// Fetches a URL and returns its response body, or throws on failure.
/// Injected so callers can supply a real HTTP client in production and a
/// deterministic fake in tests.
typedef HttpGet = Future<String> Function(Uri uri);

/// Default production [HttpGet]: a plain `dart:io` `HttpClient` GET,
/// requiring a 200 response. No new HTTP package dependency is introduced
/// for this — see design.md decision 3.
Future<String> httpGetViaHttpClient(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw HttpException(
        'GET $uri returned HTTP ${response.statusCode}: $body',
      );
    }
    return body;
  } finally {
    client.close(force: true);
  }
}

/// Fetches and parses `<issuer>/.well-known/openid-configuration`.
///
/// Throws [OidcDiscoveryException] — naming [issuer] — when the request
/// fails, the response is not valid JSON, or any of
/// `authorization_endpoint`, `token_endpoint`, `jwks_uri` is missing or
/// not a string.
Future<OidcDiscoveryDocument> fetchOidcDiscovery(
  String issuer, {
  required HttpGet httpGet,
}) async {
  final uri = Uri.parse('$issuer/.well-known/openid-configuration');
  final String body;
  try {
    body = await httpGet(uri);
  } on Object catch (e) {
    throw OidcDiscoveryException(
      'Could not fetch OIDC discovery document from issuer "$issuer": $e',
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw OidcDiscoveryException(
      'OIDC discovery document from issuer "$issuer" is not valid JSON.',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw OidcDiscoveryException(
      'OIDC discovery document from issuer "$issuer" is not a JSON object.',
    );
  }

  final authorizationEndpoint = decoded['authorization_endpoint'];
  final tokenEndpoint = decoded['token_endpoint'];
  final jwksUri = decoded['jwks_uri'];
  if (authorizationEndpoint is! String ||
      tokenEndpoint is! String ||
      jwksUri is! String) {
    throw OidcDiscoveryException(
      'OIDC discovery document from issuer "$issuer" is missing '
      'authorization_endpoint, token_endpoint, or jwks_uri.',
    );
  }

  return OidcDiscoveryDocument(
    authorizationEndpoint: authorizationEndpoint,
    tokenEndpoint: tokenEndpoint,
    jwksUri: jwksUri,
  );
}
