import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:flutter_otel_exporter_otlp_http/flutter_otel_exporter_otlp_http.dart';
import 'package:http/http.dart' as http;
import 'package:server/src/config.dart';
import 'package:server/src/otel/simple_log_record_processor.dart';
import 'package:server/src/otel/simple_logger_provider.dart';
import 'package:shared/shared.dart';

/// Builds the [LoggerProvider] the server exports logs through. When
/// [Config.otlpEndpoint] is unset, exports are a no-op (no HTTP client is
/// even required), so this is safe to wire up unconditionally.
LoggerProvider createOtelLoggerProvider(
  Config config, {
  http.Client? httpClient,
}) {
  final endpoint = config.otlpEndpoint;
  final resource = OTelResource(
    serviceName: 'robot-notes-server',
    serviceVersion: robotNotesVersion,
  );
  final LogRecordExporter exporter;
  if (endpoint == null) {
    exporter = const NoopLogRecordExporter();
  } else {
    exporter = OtlpHttpLogExporter(
      endpoint: OtlpHttpLogExporter.resolveLogsEndpoint(
        baseEndpoint: endpoint,
      )!,
      httpClient: httpClient ?? http.Client(),
      headers: config.otlpHeaders,
      ownsClient: httpClient == null,
    );
  }
  return SimpleLoggerProvider(SimpleLogRecordProcessor(exporter, resource));
}
