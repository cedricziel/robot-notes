import 'package:flutter_otel/flutter_otel.dart';
import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

/// Wraps an [http.Client] so every request sent through it opens a
/// client-kind [Span], carries a `traceparent` header derived from that
/// span, and closes the span with the response's outcome.
///
/// The server's `otelHttpTraceMiddleware` already parses an incoming
/// `traceparent` as the parent of its own request span, so wrapping the
/// app's [RobotNotesClient] http client with this makes each app action a
/// single trace spanning both the client call and the server request (and
/// whatever spans the server opens underneath it).
/// Convenience factory for the common case: every server-bound
/// `http.Client Function()` in the app (the notes API, OAuth
/// registration/token exchange, session refresh) should hand out a fresh
/// [TracingHttpClient] rather than a bare [http.Client], so every app
/// action — sign-in included — shows up as a trace.
http.Client tracingHttpClient() => TracingHttpClient(http.Client());

class TracingHttpClient extends http.BaseClient {
  TracingHttpClient(this._inner, {Tracer Function()? tracerProvider})
    : _tracerProvider = tracerProvider ?? _defaultTracer;

  final http.Client _inner;
  final Tracer Function() _tracerProvider;

  /// Resolved lazily (per request, not cached) so a later
  /// `OTelSdk.reset()`/re-`initialize()` — e.g. from `syncOtelWithConfig`
  /// picking up a newly-connected server — is picked up immediately rather
  /// than pinning whatever tracer existed when this client was constructed.
  static Tracer _defaultTracer() =>
      OTelSdk.instance.tracerProvider.getTracer(name: 'robot-notes-app');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final tracer = _tracerProvider();
    final route = _routeTemplate(request.url.path);
    final span = tracer.startSpan(
      '${request.method} $route',
      kind: SpanKind.client,
      attributes: {
        'http.method': request.method,
        'http.target': request.url.path,
      },
    );
    request.headers['traceparent'] = formatTraceparent(span.spanContext);
    try {
      final response = await _inner.send(request);
      span.setAttribute('http.status_code', response.statusCode);
      if (response.statusCode >= 500) {
        span.setStatus(StatusCode.error);
      }
      return response;
    } catch (e, stackTrace) {
      span
        ..recordException(e, stackTrace: stackTrace)
        ..setStatus(StatusCode.error, description: e.toString());
      rethrow;
    } finally {
      span.end();
    }
  }

  @override
  void close() => _inner.close();
}

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
