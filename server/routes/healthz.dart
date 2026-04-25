import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// Liveness probe.
///
/// Always returns `{"status":"ok","version":"<release>"}` with HTTP 200
/// when the server is running. The bearer-auth middleware exempts
/// `GET /healthz` so that orchestrators (Docker healthcheck, Kubernetes
/// probes, uptime monitors) can poll the endpoint without knowing the
/// API key. The version is bumped by release-please at release time.
Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: 405,
      body: const {'error': 'method_not_allowed'},
    );
  }
  return Response.json(
    body: const {'status': 'ok', 'version': robotNotesVersion},
  );
}
