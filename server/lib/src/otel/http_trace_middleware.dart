import 'package:dart_frog/dart_frog.dart';
import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:shared/shared.dart';

/// Builds a Dart Frog [Middleware] that wraps every request in a
/// server-kind span, started from [tracer].
///
/// An incoming `traceparent` header (W3C Trace Context) is parsed via
/// [parseTraceparent] and used as the span's parent when present and valid,
/// so a client-originated trace continues through this server instead of
/// starting a new one each hop. `Tracer.startActiveSpan` doesn't accept an
/// explicit parent context, so this builds the span with [Tracer.startSpan]
/// and drives the same start/record/end sequence by hand.
///
/// The span is made [Span.current] for the duration of request handling
/// (via [Span.runWithSpan]), so bridged `package:logging` records emitted
/// while handling the request pick up its trace/span ID automatically —
/// see `logging_bridge.dart`. `http.method`/`http.target`/`http.route`
/// attributes are set on start, `http.status_code` on completion (with an
/// error status for a 5xx response), and an unhandled exception is
/// recorded (with an error status) before being rethrown.
///
/// The span name and `http.route` attribute use [_routeTemplate] rather
/// than the raw request path, so per-note/per-invite IDs (ULIDs, tokens)
/// don't explode span-name cardinality in the tracing backend; the raw
/// path is still available verbatim as `http.target`.
Middleware otelHttpTraceMiddleware(Tracer tracer) {
  return (handler) {
    return (context) async {
      final request = context.request;
      final method = request.method.value;
      final route = _routeTemplate(request.uri.path);
      final parentContext = parseTraceparent(request.headers['traceparent']);
      final span = tracer.startSpan(
        '$method $route',
        kind: SpanKind.server,
        parentContext: parentContext,
        attributes: {
          'http.method': method,
          'http.target': request.uri.path,
          'http.route': route,
        },
      );
      return Span.runWithSpan(span, () async {
        try {
          final response = await handler(context);
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
      });
    };
  };
}

/// Replaces the dynamic ID/token segment of this server's two
/// parameterized route families ([Routes.notes]`/{id}/...`,
/// [Routes.invites]`/{token}/...`) with a fixed placeholder, leaving every
/// other path unchanged.
String _routeTemplate(String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length >= 2 && '/${segments[0]}' == Routes.notes) {
    segments[1] = ':id';
  } else if (segments.length >= 2 && '/${segments[0]}' == Routes.invites) {
    segments[1] = ':token';
  }
  return '/${segments.join('/')}';
}
