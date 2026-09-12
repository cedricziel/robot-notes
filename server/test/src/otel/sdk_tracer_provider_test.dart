import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/sdk_tracer_provider.dart';
import 'package:test/test.dart';

class _FakeSpanProcessor implements SpanProcessor {
  bool flushed = false;
  bool shutdownCalled = false;

  @override
  void onEnd(SpanData span) {}

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
