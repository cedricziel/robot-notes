import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/sdk_tracer.dart';

/// Concrete [TracerProvider] backed by a single [SpanProcessor]. Mirrors
/// `flutter_otel_sdk`'s `SdkTracerProvider`, ported here for the same reason
/// as [SdkTracer] — see `sdk_span.dart`'s doc comment.
///
/// Caches vended tracers by a `(name, version)` compound key (a Dart
/// record), the same collision-free pattern `SdkLoggerProvider` uses,
/// rather than a delimiter-joined string that could collide across
/// differing name/version pairs.
class SdkTracerProvider implements TracerProvider {
  /// Creates a provider whose vended tracers all forward ended spans to the
  /// given [processor].
  SdkTracerProvider({required this.processor});

  /// The processor every tracer vended by this provider forwards ended
  /// spans to.
  final SpanProcessor processor;

  final Map<(String, String?), Tracer> _tracers = {};

  @override
  Tracer getTracer({String name = 'flutter_otel', String? version}) {
    final key = (name, version);
    return _tracers.putIfAbsent(
      key,
      () => SdkTracer(name: name, version: version, processor: processor),
    );
  }

  @override
  void ingestSpan(SpanData span) => processor.onEnd(span);

  @override
  Future<void> forceFlush() => processor.forceFlush();

  @override
  Future<void> shutdown() => processor.shutdown();
}
