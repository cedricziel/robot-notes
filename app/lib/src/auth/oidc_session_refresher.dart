import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../config/app_config.dart';

/// A rejected or malformed token refresh response. Retry transient failures.
@immutable
class OidcRefreshException implements Exception {
  /// Creates the exception wrapping a human-readable [message].
  const OidcRefreshException(this.message, {this.retryable = false});

  final bool retryable;

  /// Detail suitable for a log line — never the token itself.
  final String message;

  @override
  String toString() => 'OidcRefreshException: $message';
}

/// Refreshes an OIDC-backed [AppConfig] via `POST /oauth/token`
/// (`grant_type=refresh_token`), rotating both the access and refresh
/// token per the server's own token endpoint.
class OidcSessionRefresher {
  /// Creates a refresher using [_clientFactory] to build a fresh
  /// [http.Client] per request.
  OidcSessionRefresher({required this._clientFactory});

  final http.Client Function() _clientFactory;

  /// Returns a copy of [config] with a freshly rotated access/refresh
  /// token pair. Throws [ArgumentError] if [config] is not an OIDC
  /// session ([AppConfig.isOidcSession] is `false`), and
  /// [OidcRefreshException] if the refresh itself fails.
  Future<AppConfig> refresh(AppConfig config) async {
    if (!config.isOidcSession) {
      throw ArgumentError.value(
        config,
        'config',
        'is not an OIDC session (no refresh token to use).',
      );
    }

    final client = _clientFactory();
    try {
      final response = await client
          .post(
            Uri.parse('${config.baseUrl}/oauth/token'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'grant_type': 'refresh_token',
              'refresh_token': config.oauthRefreshToken!,
              'client_id': config.oauthClientId!,
            },
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw OidcRefreshException(
          'Token refresh failed with HTTP ${response.statusCode}.',
          retryable: response.statusCode == 429 || response.statusCode >= 500,
        );
      }
      final decoded = jsonDecode(response.body);
      final accessToken = decoded is Map<String, dynamic>
          ? decoded['access_token']
          : null;
      final refreshToken = decoded is Map<String, dynamic>
          ? decoded['refresh_token']
          : null;
      if (accessToken is! String || refreshToken is! String) {
        throw const OidcRefreshException(
          'Token refresh response was missing access_token or '
          'refresh_token.',
        );
      }
      return AppConfig(
        baseUrl: config.baseUrl,
        apiKey: accessToken,
        actor: config.actor,
        vaultId: config.vaultId,
        oauthClientId: config.oauthClientId,
        oauthRefreshToken: refreshToken,
      );
    } on http.ClientException {
      throw const OidcRefreshException(
        'Token refresh could not reach the server.',
        retryable: true,
      );
    } on TimeoutException {
      throw const OidcRefreshException(
        'Token refresh timed out.',
        retryable: true,
      );
    } on FormatException {
      throw const OidcRefreshException('Token refresh response was malformed.');
    } finally {
      client.close();
    }
  }
}
