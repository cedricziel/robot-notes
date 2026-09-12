import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/config.dart';

/// Runtime OpenTelemetry export config for clients (the web bundle and the
/// native app), sourced from the same `--otel-endpoint`/`--otel-headers` /
/// `ROBOT_NOTES_OTEL_ENDPOINT`/`ROBOT_NOTES_OTEL_HEADERS` config the server
/// itself uses. Lets every client enable telemetry at runtime by pointing at
/// a server that has it configured, instead of baking an operator's
/// endpoint/key into the distributed app or web bundle at build time.
///
/// `{"enabled": false}` when unset. Unauthenticated, like `/healthz` — the
/// headers value is expected to carry an ingest-only key, never an admin
/// credential, since it is handed to any client that asks.
Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: 405,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final config = context.read<Config>();
  final endpoint = config.otlpEndpoint;
  final body = endpoint == null
      ? const {'enabled': false}
      : {
          'enabled': true,
          'endpoint': endpoint.toString(),
          'headers': config.otlpHeaders,
        };
  return Response.json(
    body: body,
    headers: const {'cache-control': 'no-store'},
  );
}
