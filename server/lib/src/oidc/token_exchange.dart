import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// Posts a form-urlencoded [form] body to [uri] and returns the response
/// body. Injected so callers can supply a real HTTP client in production
/// and a deterministic fake in tests.
typedef HttpPostForm = Future<String> Function(
  Uri uri,
  Map<String, String> form,
);

/// Thrown by [exchangeCodeForIdToken] when the exchange request fails, the
/// response is not valid JSON, or it has no `id_token`.
@immutable
class OidcTokenExchangeException implements Exception {
  /// Creates the exception wrapping a human-readable [message].
  const OidcTokenExchangeException(this.message);

  /// Detail suitable for a log — never logged with token material.
  final String message;

  @override
  String toString() => 'OidcTokenExchangeException: $message';
}

/// Exchanges an authorization [code] at the provider's [tokenEndpoint]
/// using the authorization-code grant with PKCE, and returns the
/// resulting `id_token`.
///
/// Only the ID token is used — any `access_token`/`refresh_token` the
/// provider returns is discarded, per the `oidc-login` capability's
/// "login is an event, not an ongoing session" design (design.md
/// decision 1).
Future<String> exchangeCodeForIdToken({
  required String tokenEndpoint,
  required String code,
  required String redirectUri,
  required String codeVerifier,
  required String clientId,
  required String clientSecret,
  required HttpPostForm httpPost,
}) async {
  final String body;
  try {
    body = await httpPost(Uri.parse(tokenEndpoint), {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': codeVerifier,
      'client_id': clientId,
      'client_secret': clientSecret,
    });
  } on Object catch (e) {
    throw OidcTokenExchangeException(
      'Code exchange at "$tokenEndpoint" failed: $e',
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw const OidcTokenExchangeException(
      'Token endpoint response is not valid JSON.',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw const OidcTokenExchangeException(
      'Token endpoint response is not a JSON object.',
    );
  }

  final idToken = decoded['id_token'];
  if (idToken is! String) {
    throw const OidcTokenExchangeException(
      'Token endpoint response has no id_token.',
    );
  }
  return idToken;
}

/// Default production [HttpPostForm]: a plain `dart:io` `HttpClient` POST
/// with an `application/x-www-form-urlencoded` body, requiring a 200
/// response. No new HTTP package dependency for this — see
/// `discovery.dart`'s `httpGetViaHttpClient`.
Future<String> httpPostFormViaHttpClient(
  Uri uri,
  Map<String, String> form,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    final body = form.entries
        .map(
          (e) => '${Uri.encodeQueryComponent(e.key)}='
              '${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    request.write(body);
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw HttpException(
        'POST $uri returned HTTP ${response.statusCode}: $responseBody',
      );
    }
    return responseBody;
  } finally {
    client.close(force: true);
  }
}
