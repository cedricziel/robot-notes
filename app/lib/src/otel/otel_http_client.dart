import 'package:dart_otel_instrumentation_http/dart_otel_instrumentation_http.dart';
import 'package:flutter_otel/flutter_otel.dart';
import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

/// Hands out an [http.Client] that traces every request: a client-kind span
/// with a `traceparent` header derived from it, plus the request/response
/// headers as OTel semantic-convention attributes with credentials redacted.
///
/// The server's `otelHttpTraceMiddleware` parses an incoming `traceparent` as
/// the parent of its own request span, so each app action becomes a single
/// trace spanning both the client call and the server request.
///
/// Every server-bound `http.Client Function()` in the app (the notes API,
/// OAuth registration/token exchange, session refresh) should use this rather
/// than a bare [http.Client], so every app action — sign-in included — shows
/// up as a trace.
///
/// The tracer is resolved per request, not cached, so a later
/// `OTelSdk.reset()`/re-`initialize()` — e.g. from `syncOtelWithConfig`
/// picking up a newly-connected server — is picked up immediately.
http.Client tracingHttpClient({
  http.Client? inner,
  Tracer Function()? tracerProvider,
}) => TracingHttpClient(
  inner ?? http.Client(),
  tracerProvider: tracerProvider ?? _defaultTracer,
  routeTemplate: _routeTemplate,
);

Tracer _defaultTracer() =>
    OTelSdk.instance.tracerProvider.getTracer(name: 'robot-notes-app');

/// Replaces a note ID segment (`/notes/{id}/...`) with a fixed placeholder
/// so per-note ULIDs don't explode span-name cardinality — mirrors the
/// server's `_routeTemplate` in `http_trace_middleware.dart`. The app never
/// calls any other parameterized route.
String _routeTemplate(String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length >= 2 && '/${segments[0]}' == Routes.notes) {
    segments[1] = ':id';
  }
  return '/${segments.join('/')}';
}
