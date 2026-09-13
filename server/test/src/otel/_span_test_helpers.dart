import 'dart:async';

import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:flutter_otel_sdk/flutter_otel_sdk.dart' show SdkTracer;

/// A [SpanProcessor] that just remembers every span passed to [onEnd], for
/// a test to inspect once the traced code has run.
class RecordingProcessor implements SpanProcessor {
  final List<SpanData> ended = [];

  @override
  void onEnd(SpanData span) => ended.add(span);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

/// Runs [body] with a fresh span active, ends it, and returns both [body]'s
/// result and the span data recorded — so a test can assert an attribute
/// [body] set on [Span.current] alongside whatever [body] itself returns.
Future<(T, SpanData)> spanFor<T>(FutureOr<T> Function() body) async {
  final processor = RecordingProcessor();
  final tracer = SdkTracer(name: 'test', version: null, processor: processor);
  final span = tracer.startSpan('test', kind: SpanKind.server);
  final result = await Span.runWithSpan(span, () async => body());
  span.end();
  return (result, processor.ended.single);
}
