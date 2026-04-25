import 'package:flutter/foundation.dart';

/// Three pieces of configuration the user supplies at first-run:
///   * [baseUrl] — fully qualified server origin, e.g. `https://notes.example`.
///   * [apiKey] — single bearer credential issued by the operator.
///   * [actor] — display identity (`X-Actor`) for events/locks.
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
  });

  final String baseUrl;
  final String apiKey;
  final String actor;

  /// Returns a copy with a normalized [baseUrl] (trailing slash stripped) so
  /// path concatenation `<baseUrl>/notes` is unambiguous downstream.
  AppConfig normalized() {
    final trimmed = baseUrl.trim();
    final stripped = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    return AppConfig(baseUrl: stripped, apiKey: apiKey, actor: actor.trim());
  }

  Map<String, String> toJson() => {
        'base_url': baseUrl,
        'api_key': apiKey,
        'actor': actor,
      };

  factory AppConfig.fromJson(Map<String, String> json) => AppConfig(
        baseUrl: json['base_url'] ?? '',
        apiKey: json['api_key'] ?? '',
        actor: json['actor'] ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is AppConfig &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.actor == actor;

  @override
  int get hashCode => Object.hash(baseUrl, apiKey, actor);

  /// Intentionally redacts [apiKey] so no caller can `print(config)` the key.
  @override
  String toString() => 'AppConfig(baseUrl: $baseUrl, actor: $actor, '
      'apiKey: <redacted>)';
}
