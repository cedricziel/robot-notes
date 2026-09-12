import 'package:flutter/foundation.dart';

/// OTel export settings, resolved at runtime by fetching `{baseUrl}/otel-config`
/// from the connected server (see `remote_otel_config.dart`) — an ops/
/// deployment value, not user-entered data, so it deliberately lives outside
/// the app's secure-storage user configuration.
@immutable
class OtelBuildConfig {
  const OtelBuildConfig({this.endpoint, this.headers = const {}});

  /// Base OTLP/HTTP endpoint telemetry is exported to. `null` disables
  /// export entirely.
  final Uri? endpoint;

  /// Extra headers (e.g. an auth token) sent with every OTLP export
  /// request.
  final Map<String, String> headers;
}
