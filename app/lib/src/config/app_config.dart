import 'package:flutter/foundation.dart';

/// Configuration the app authenticates with, supplied either by manually
/// pasting an API key or by completing an OIDC sign-in:
///   * [baseUrl] — fully qualified server origin, e.g. `https://notes.example`.
///   * [apiKey] — the current bearer credential sent as `Authorization:
///     Bearer` followed by this value, and in the WebSocket `auth`
///     message. For a manual
///     session this is the operator-issued static key; for an OIDC
///     session this is the server's own OAuth access token — the server
///     accepts either credential shape identically, so nothing downstream
///     of this field needs to know which kind it is.
///   * [actor] — display identity (`X-Actor`) for events/locks. Ignored
///     by the server for an OIDC session (the verified identity wins),
///     but still sent for the manual-key path.
///   * [oauthClientId] / [oauthRefreshToken] — present only for an OIDC
///     session, `null` for a manual key. Used to refresh [apiKey] via
///     `POST /oauth/token` once it expires.
///
/// Persisted via [ConfigStore] after the setup screen successfully
/// validates the values against `GET /notes?limit=1`. The class is
/// immutable and value-equal so tests can use it as a literal.
@immutable
class AppConfig {
  const AppConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.actor,
    this.oauthClientId,
    this.oauthRefreshToken,
  });

  final String baseUrl;
  final String apiKey;
  final String actor;
  final String? oauthClientId;
  final String? oauthRefreshToken;

  /// Whether this session came from an OIDC sign-in rather than a
  /// manually entered key.
  bool get isOidcSession => oauthRefreshToken != null;

  /// Returns a copy with a normalized [baseUrl] (trailing slash stripped) so
  /// path concatenation `<baseUrl>/notes` is unambiguous downstream.
  AppConfig normalized() {
    final trimmed = baseUrl.trim();
    final stripped = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    return AppConfig(
      baseUrl: stripped,
      apiKey: apiKey,
      actor: actor.trim(),
      oauthClientId: oauthClientId,
      oauthRefreshToken: oauthRefreshToken,
    );
  }

  Map<String, String> toJson() => {
    'base_url': baseUrl,
    'api_key': apiKey,
    'actor': actor,
    'oauth_client_id': ?oauthClientId,
    'oauth_refresh_token': ?oauthRefreshToken,
  };

  factory AppConfig.fromJson(Map<String, String> json) => AppConfig(
    baseUrl: json['base_url'] ?? '',
    apiKey: json['api_key'] ?? '',
    actor: json['actor'] ?? '',
    oauthClientId: json['oauth_client_id'],
    oauthRefreshToken: json['oauth_refresh_token'],
  );

  @override
  bool operator ==(Object other) =>
      other is AppConfig &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.actor == actor &&
      other.oauthClientId == oauthClientId &&
      other.oauthRefreshToken == oauthRefreshToken;

  @override
  int get hashCode =>
      Object.hash(baseUrl, apiKey, actor, oauthClientId, oauthRefreshToken);

  /// Intentionally redacts [apiKey] and [oauthRefreshToken] so no caller
  /// can `print(config)` a live credential.
  @override
  String toString() =>
      'AppConfig(baseUrl: $baseUrl, actor: $actor, '
      'apiKey: <redacted>, isOidcSession: $isOidcSession)';
}
