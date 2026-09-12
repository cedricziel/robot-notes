import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../config/app_config.dart';

/// Thrown by [OidcSessionRefresher.refresh] when the refresh request
/// fails or the response is malformed. A caller SHOULD treat this as
/// "the session is no longer valid" and fall back to the setup screen.
@immutable
class OidcRefreshException implements Exception {
  /// Creates the exception wrapping a human-readable [message].
  const OidcRefreshException(this.message);

  /// Detail suitable for a log line — never the token itself.
  final String message;

  @override
  String toString() => 'OidcRefreshException: $message';
}

/// Refreshes an OIDC-backed [AppConfig] via `POST /oauth/token`
/// (`grant_type=refresh_token`), rotating both the access and refresh
/// token per the server's own token endpoint.
///
/// Since each app installation manages its own independent session (no
/// cross-device sync), refreshing unconditionally on every app launch is
/// simpler and just as correct as tracking an expiry timestamp: the new
/// tokens are persisted immediately, and a rejected refresh token means
/// the session needs a fresh sign-in.
class OidcSessionRefresher {
  /// Creates a refresher using [clientFactory] to build a fresh
  /// [http.Client] per request.
  OidcSessionRefresher({required http.Client Function() clientFactory})
    : _clientFactory = clientFactory;

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
      final response = await client.post(
        Uri.parse('${config.baseUrl}/oauth/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': config.oauthRefreshToken!,
          'client_id': config.oauthClientId!,
        },
      );
      if (response.statusCode != 200) {
        throw OidcRefreshException(
          'Token refresh failed with HTTP ${response.statusCode}.',
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
        oauthClientId: config.oauthClientId,
        oauthRefreshToken: refreshToken,
      );
    } finally {
      client.close();
    }
  }
}
