import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/otel_tracer_holder.dart';
import 'package:test/test.dart';

class _FakeTracerProvider implements TracerProvider {
  @override
  Tracer getTracer({String name = 'flutter_otel', String? version}) =>
      throw UnimplementedError();

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

void main() {
  setUp(debugResetOtelTracerProvider);
  tearDown(debugResetOtelTracerProvider);

  group('otel_tracer_holder', () {
    test('otelTracerProvider getter throws StateError before set', () {
      expect(() => otelTracerProvider, throwsStateError);
    });

    test('otelTracerProvider getter returns the value installed by set', () {
      const provider = NoopTracerProvider();
      setOtelTracerProvider(provider);
      expect(identical(otelTracerProvider, provider), isTrue);
    });

    test('setOtelTracerProvider is idempotent for the same instance', () {
      const provider = NoopTracerProvider();
      setOtelTracerProvider(provider);
      expect(() => setOtelTracerProvider(provider), returnsNormally);
      expect(identical(otelTracerProvider, provider), isTrue);
    });

    test('setOtelTracerProvider throws when called with a different instance',
        () {
      setOtelTracerProvider(_FakeTracerProvider());
      expect(
        () => setOtelTracerProvider(_FakeTracerProvider()),
        throwsStateError,
      );
    });

    test('debugResetOtelTracerProvider clears the holder', () {
      setOtelTracerProvider(const NoopTracerProvider());
      debugResetOtelTracerProvider();
      expect(() => otelTracerProvider, throwsStateError);
    });
  });
}
