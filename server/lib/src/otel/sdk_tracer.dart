import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/sdk_span.dart';

/// Concrete [Tracer] backed by a [SpanProcessor]. Mirrors `flutter_otel_sdk`'s
/// `SdkTracer`, ported here for the same reason as [SdkSpan] — see that
/// file's doc comment.
///
/// Resolves the parent span context as: an explicit [startSpan]
/// `parentContext` argument, then the ambient [Span.current], then no
/// parent (a root span).
class SdkTracer implements Tracer {
  /// Creates a tracer for the `(name, version)` instrumentation scope,
  /// handing every span it starts to [processor] on `end()`.
  SdkTracer({
    required this.name,
    required this.version,
    required SpanProcessor processor,
  }) : _processor = processor;

  @override
  final String name;

  /// This tracer's instrumentation scope version, if any.
  final String? version;

  final SpanProcessor _processor;

  @override
  Span startSpan(
    String name, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?>? attributes,
    SpanContext? parentContext,
  }) {
    final resolvedParent = parentContext ?? Span.current?.spanContext;
    return SdkSpan(
      name: name,
      kind: kind,
      parentContext: resolvedParent,
      parentSpanId: resolvedParent?.spanId,
      processor: _processor,
      attributes: attributes,
      scopeName: this.name,
      scopeVersion: version,
    );
  }

  @override
  Future<T> startActiveSpan<T>(
    String name,
    Future<T> Function(Span span) body, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?>? attributes,
  }) async {
    final span = startSpan(name, kind: kind, attributes: attributes);
    try {
      return await Span.runWithSpan(span, () => body(span));
    } catch (e, stackTrace) {
      span
        ..recordException(e, stackTrace: stackTrace)
        ..setStatus(StatusCode.error, description: e.toString());
      rethrow;
    } finally {
      span.end();
    }
  }
}
