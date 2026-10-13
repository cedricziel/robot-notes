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
///
/// Every attempt is bounded by [requestTimeout] (issue #419: an unbounded
/// refresh once hung for ~1 hour on a stale keep-alive connection while
/// the server had already answered) and a retryable failure is retried
/// once on a FRESH connection: [_clientFactory] is called again, so no
/// pooled connection is reused after it has proven unresponsive.
class OidcSessionRefresher {
  /// Creates a refresher using [_clientFactory] to build a fresh
  /// [http.Client] per request.
  OidcSessionRefresher({required this._clientFactory});

  final http.Client Function() _clientFactory;

  /// How long a single token-refresh request may take (connect + receive).
  /// Token refreshes are latency-critical: fail fast rather than leaving
  /// the session unusable for minutes. Deliberately per attempt — worst
  /// case [maxAttempts] × this bound.
  static const Duration requestTimeout = Duration(seconds: 10);

  /// Total attempts per refresh: one on the original connection, one on a
  /// fresh one after a retryable failure.
  static const int maxAttempts = 2;

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

    for (var attempt = 1; ; attempt++) {
      final lastAttempt = attempt == maxAttempts;
      // A fresh client per attempt: a retry must never reuse the pooled
      // connection that just failed.
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
                if (config.oauthRefreshRequestId != null)
                  'refresh_request_id': config.oauthRefreshRequestId!,
              },
            )
            .timeout(requestTimeout);
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
          oauthRefreshRequestId: generateRefreshRequestId(),
        );
      } on OidcRefreshException catch (error) {
        // Non-retryable (e.g. invalid_grant) surfaces immediately; a
        // retryable one gets one fresh-connection retry.
        if (lastAttempt || !error.retryable) rethrow;
      } on http.ClientException {
        if (lastAttempt) {
          throw const OidcRefreshException(
            'Token refresh could not reach the server.',
            retryable: true,
          );
        }
      } on TimeoutException {
        if (lastAttempt) {
          throw const OidcRefreshException(
            'Token refresh timed out.',
            retryable: true,
          );
        }
      } on FormatException {
        throw const OidcRefreshException(
          'Token refresh response was malformed.',
        );
      } finally {
        client.close();
      }
    }
  }
}
