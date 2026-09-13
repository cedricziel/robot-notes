import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:flutter_otel_exporter_otlp_http/flutter_otel_exporter_otlp_http.dart';
import 'package:http/http.dart' as http;
import 'package:server/src/config.dart';
import 'package:server/src/otel/sdk_tracer_provider.dart';
import 'package:server/src/otel/simple_log_record_processor.dart';
import 'package:server/src/otel/simple_logger_provider.dart';
import 'package:server/src/otel/simple_span_processor.dart';
import 'package:shared/shared.dart';

/// Builds the [OTelResource] every server signal is exported under:
/// `service.name`/`service.version` identify this process, `service.
/// namespace` groups it with the app and probe as one system, and
/// `deployment.environment.name` (from [Config.otelEnvironmentName]) says
/// which deployment produced the telemetry.
OTelResource _resource(Config config) => OTelResource(
      serviceName: 'robot-notes-server',
      serviceVersion: robotNotesVersion,
      attributes: {
        'service.namespace': otelServiceNamespace,
        'deployment.environment.name': config.otelEnvironmentName,
      },
    );

/// Builds the [LoggerProvider] the server exports logs through. When
/// [Config.otlpEndpoint] is unset, exports are a no-op (no HTTP client is
/// even required), so this is safe to wire up unconditionally.
LoggerProvider createOtelLoggerProvider(
  Config config, {
  http.Client? httpClient,
}) {
  final endpoint = config.otlpEndpoint;
  final resource = _resource(config);
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

/// Builds the [TracerProvider] the server exports spans through. When
/// [Config.otlpEndpoint] is unset, exports are a no-op (no HTTP client is
/// even required), so this is safe to wire up unconditionally.
TracerProvider createOtelTracerProvider(
  Config config, {
  http.Client? httpClient,
}) {
  final endpoint = config.otlpEndpoint;
  final resource = _resource(config);
  final SpanExporter exporter;
  if (endpoint == null) {
    exporter = const NoopSpanExporter();
  } else {
    exporter = OtlpHttpSpanExporter(
      endpoint: OtlpHttpSpanExporter.resolveTracesEndpoint(
        baseEndpoint: endpoint,
      )!,
      httpClient: httpClient ?? http.Client(),
      headers: config.otlpHeaders,
      ownsClient: httpClient == null,
    );
  }
  return SdkTracerProvider(
    processor: SimpleSpanProcessor(exporter, resource),
  );
}
