import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/sdk_tracer.dart';
import 'package:test/test.dart';

class _RecordingProcessor implements SpanProcessor {
  final List<SpanData> ended = [];

  @override
  void onEnd(SpanData span) => ended.add(span);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

void main() {
  group('SdkTracer', () {
    test(
      'startSpan with no parent context and no active span is a root span',
      () {
        final tracer = SdkTracer(
          name: 'test-scope',
          version: null,
          processor: _RecordingProcessor(),
        );

        final span = tracer.startSpan('op');

        expect(span.spanContext.isValid, isTrue);
      },
    );

    test('startSpan resolves the parent from an explicit parentContext', () {
      final processor = _RecordingProcessor();
      final tracer = SdkTracer(
        name: 'scope',
        version: null,
        processor: processor,
      );
      const parent = SpanContext(
        traceId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        spanId: 'bbbbbbbbbbbbbbbb',
      );

      tracer.startSpan('child', parentContext: parent).end();

      final data = processor.ended.single;
      expect(data.spanContext.traceId, parent.traceId);
      expect(data.parentSpanId, parent.spanId);
    });

    test('startSpan resolves the parent from the ambient Span.current',
        () async {
      final processor = _RecordingProcessor();
      final tracer = SdkTracer(
        name: 'scope',
        version: null,
        processor: processor,
      );
      final parentSpan = tracer.startSpan('parent');

      await Span.runWithSpan(parentSpan, () async {
        tracer.startSpan('child').end();
      });

      final data = processor.ended.single;
      expect(data.spanContext.traceId, parentSpan.spanContext.traceId);
      expect(data.parentSpanId, parentSpan.spanContext.spanId);
    });

    test('startActiveSpan ends the span and returns the body result', () async {
      final processor = _RecordingProcessor();
      final tracer = SdkTracer(
        name: 'scope',
        version: null,
        processor: processor,
      );

      final result = await tracer.startActiveSpan('op', (span) async {
        expect(Span.current, same(span));
        return 42;
      });

      expect(result, 42);
      expect(processor.ended, hasLength(1));
      expect(processor.ended.single.name, 'op');
    });

    test(
        'startActiveSpan records the exception, sets an error status, and '
        'rethrows', () async {
      final processor = _RecordingProcessor();
      final tracer = SdkTracer(
        name: 'scope',
        version: null,
        processor: processor,
      );

      await expectLater(
        tracer.startActiveSpan('op', (span) async {
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );

      final data = processor.ended.single;
      expect(data.statusCode, StatusCode.error);
      expect(data.statusDescription, contains('boom'));
      expect(data.events.single.name, 'exception');
    });
  });
}
