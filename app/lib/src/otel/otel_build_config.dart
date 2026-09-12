import 'package:flutter/foundation.dart';

/// OTel export settings baked in at build time via `--dart-define`
/// (`OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_HEADERS`), mirroring
/// the standard OTel env var names. This is an ops/deployment value, not
/// user-entered data, so it deliberately lives outside the app's
/// secure-storage user configuration.
@immutable
class OtelBuildConfig {
  const OtelBuildConfig({this.endpoint, this.headers = const {}});

  /// Base OTLP/HTTP endpoint telemetry is exported to. `null` disables
  /// export entirely.
  final Uri? endpoint;

  /// Extra headers (e.g. an auth token) sent with every OTLP export
  /// request.
  final Map<String, String> headers;

  /// Parses raw `--dart-define` string values. Throws [FormatException]
  /// when [rawEndpoint] is non-empty but not an absolute http(s) URL with a
  /// host, or when a [rawHeaders] entry has no `=`.
  factory OtelBuildConfig.parse({
    required String rawEndpoint,
    required String rawHeaders,
  }) {
    Uri? endpoint;
    if (rawEndpoint.isNotEmpty) {
      final uri = Uri.tryParse(rawEndpoint);
      final valid =
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty;
      if (!valid) {
        throw FormatException(
          'Invalid OTEL_EXPORTER_OTLP_ENDPOINT value "$rawEndpoint": must '
          'be an absolute http or https URL with a host.',
        );
      }
      endpoint = uri;
    }

    final headers = <String, String>{};
    if (rawHeaders.isNotEmpty) {
      for (final entry in rawHeaders.split(',')) {
        final separator = entry.indexOf('=');
        if (separator <= 0) {
          throw FormatException(
            'Invalid OTEL_EXPORTER_OTLP_HEADERS entry "$entry": expected '
            '"key=value".',
          );
        }
        headers[entry.substring(0, separator)] = entry.substring(separator + 1);
      }
    }

    return OtelBuildConfig(endpoint: endpoint, headers: headers);
  }

  /// Reads the `--dart-define`d values baked in at compile time.
  factory OtelBuildConfig.fromEnvironment() => OtelBuildConfig.parse(
    rawEndpoint: const String.fromEnvironment('OTEL_EXPORTER_OTLP_ENDPOINT'),
    rawHeaders: const String.fromEnvironment('OTEL_EXPORTER_OTLP_HEADERS'),
  );
}
