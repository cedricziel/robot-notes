import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/sdk_tracer_provider.dart';
import 'package:test/test.dart';

class _FakeSpanProcessor implements SpanProcessor {
  final List<SpanData> ended = [];
  bool flushed = false;
  bool shutdownCalled = false;

  @override
  void onEnd(SpanData span) => ended.add(span);

  @override
  Future<void> forceFlush() async {
    flushed = true;
  }

  @override
  Future<void> shutdown() async {
    shutdownCalled = true;
  }
}

void main() {
  group('SdkTracerProvider', () {
    test('getTracer caches by (name, version)', () {
      final provider = SdkTracerProvider(processor: _FakeSpanProcessor());

      final a = provider.getTracer(name: 'scope', version: '1.0');
      final b = provider.getTracer(name: 'scope', version: '1.0');
      final c = provider.getTracer(name: 'scope', version: '2.0');

      expect(identical(a, b), isTrue);
      expect(identical(a, c), isFalse);
    });

    test('ingestSpan forwards straight to the processor', () {
      final processor = _FakeSpanProcessor();
      final provider = SdkTracerProvider(processor: processor);
      final span = SpanData(
        name: 'op',
        spanContext: const SpanContext(
          traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
          spanId: '00f067aa0ba902b7',
        ),
        startTime: DateTime.now(),
        endTime: DateTime.now(),
      );

      provider.ingestSpan(span);

      expect(processor.ended, [span]);
    });

    test('forceFlush and shutdown delegate to the processor', () async {
      final processor = _FakeSpanProcessor();
      final provider = SdkTracerProvider(processor: processor);

      await provider.forceFlush();
      expect(processor.flushed, isTrue);

      await provider.shutdown();
      expect(processor.shutdownCalled, isTrue);
    });
  });
}
