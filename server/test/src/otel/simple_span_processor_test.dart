import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/simple_span_processor.dart';
import 'package:test/test.dart';

SpanData _spanData(String name) => SpanData(
      name: name,
      spanContext: const SpanContext(
        traceId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        spanId: 'bbbbbbbbbbbbbbbb',
      ),
      startTime: DateTime.now(),
      endTime: DateTime.now(),
    );

class _FakeSpanExporter implements SpanExporter {
  final List<List<SpanData>> exported = [];
  final List<OTelResource> resources = [];
  bool shutdownCalled = false;
  ExportResult result = const ExportResult.success();

  @override
  Future<ExportResult> export(
    List<SpanData> spans,
    OTelResource resource,
  ) async {
    exported.add(spans);
    resources.add(resource);
    return result;
  }

  @override
  Future<void> shutdown() async {
    shutdownCalled = true;
  }
}

void main() {
  group('SimpleSpanProcessor', () {
    final resource = OTelResource(serviceName: 'test-service');

    test('exports each span immediately, one at a time', () async {
      final exporter = _FakeSpanExporter();
      final processor = SimpleSpanProcessor(exporter, resource)
        ..onEnd(_spanData('first'))
        ..onEnd(_spanData('second'));
      await processor.forceFlush();

      expect(exporter.exported, [
        [isA<SpanData>().having((s) => s.name, 'name', 'first')],
        [isA<SpanData>().having((s) => s.name, 'name', 'second')],
      ]);
      expect(exporter.resources, [resource, resource]);
    });

    test('forceFlush waits for in-flight export work', () async {
      final exporter = _FakeSpanExporter();
      final processor = SimpleSpanProcessor(exporter, resource)
        ..onEnd(_spanData('x'));

      await processor.forceFlush();

      expect(exporter.exported, hasLength(1));
    });

    test('shutdown flushes and shuts down the exporter', () async {
      final exporter = _FakeSpanExporter();
      final processor = SimpleSpanProcessor(exporter, resource)
        ..onEnd(_spanData('x'));
      await processor.shutdown();

      expect(exporter.exported, hasLength(1));
      expect(exporter.shutdownCalled, isTrue);
    });

    test('drops spans emitted after shutdown', () async {
      final exporter = _FakeSpanExporter();
      final processor = SimpleSpanProcessor(exporter, resource);

      await processor.shutdown();
      processor.onEnd(_spanData('too late'));
      await processor.forceFlush();

      expect(exporter.exported, isEmpty);
    });
  });
}
