import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/sdk_span.dart';
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
  group('generateTraceId / generateSpanId', () {
    test('produce correctly sized lowercase hex, and never repeat', () {
      final traceId = generateTraceId();
      final spanId = generateSpanId();

      expect(traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(spanId, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(generateTraceId(), isNot(traceId));
      expect(generateSpanId(), isNot(spanId));
    });
  });

  group('SdkSpan', () {
    test('root span gets a fresh trace ID and no parent span ID', () {
      final processor = _RecordingProcessor();
      SdkSpan(
        name: 'root',
        kind: SpanKind.internal,
        processor: processor,
      ).end();

      final data = processor.ended.single;
      expect(data.spanContext.traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(data.parentSpanId, isNull);
    });

    test('child span inherits the trace ID and records the parent span ID', () {
      final processor = _RecordingProcessor();
      const parentContext = SpanContext(
        traceId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        spanId: 'bbbbbbbbbbbbbbbb',
      );
      SdkSpan(
        name: 'child',
        kind: SpanKind.internal,
        parentContext: parentContext,
        parentSpanId: parentContext.spanId,
        processor: processor,
      ).end();

      final data = processor.ended.single;
      expect(data.spanContext.traceId, parentContext.traceId);
      expect(data.spanContext.spanId, isNot(parentContext.spanId));
      expect(data.parentSpanId, parentContext.spanId);
    });

    test('isRecording is true until end() is called', () {
      final processor = _RecordingProcessor();
      final span = SdkSpan(
        name: 's',
        kind: SpanKind.internal,
        processor: processor,
      );

      expect(span.isRecording, isTrue);
      span.end();
      expect(span.isRecording, isFalse);
    });

    test(
      'setAttribute/setAttributes/addEvent are captured in the snapshot',
      () {
        final processor = _RecordingProcessor();
        SdkSpan(
          name: 's',
          kind: SpanKind.server,
          processor: processor,
          attributes: {'http.method': 'GET'},
        )
          ..setAttribute('http.route', '/notes')
          ..setAttributes({'http.status_code': 200})
          ..addEvent('cache.miss', attributes: {'key': 'abc'})
          ..end();

        final data = processor.ended.single;
        expect(data.attributes, {
          'http.method': 'GET',
          'http.route': '/notes',
          'http.status_code': 200,
        });
        expect(data.events, hasLength(1));
        expect(data.events.single.name, 'cache.miss');
        expect(data.events.single.attributes, {'key': 'abc'});
        expect(data.kind, SpanKind.server);
      },
    );

    test('recordException adds an exception event without changing status', () {
      final processor = _RecordingProcessor();
      SdkSpan(name: 's', kind: SpanKind.internal, processor: processor)
        ..recordException(StateError('bad'), stackTrace: StackTrace.empty)
        ..end();

      final data = processor.ended.single;
      expect(data.statusCode, StatusCode.unset);
      final event = data.events.single;
      expect(event.name, 'exception');
      expect(event.attributes['exception.type'], 'StateError');
      expect(event.attributes['exception.message'], contains('bad'));
    });

    test('setStatus records the final status and description', () {
      final processor = _RecordingProcessor();
      SdkSpan(name: 's', kind: SpanKind.internal, processor: processor)
        ..setStatus(StatusCode.error, description: 'boom')
        ..end();

      final data = processor.ended.single;
      expect(data.statusCode, StatusCode.error);
      expect(data.statusDescription, 'boom');
    });

    test('mutations after end() are no-ops', () {
      final processor = _RecordingProcessor();
      SdkSpan(name: 's', kind: SpanKind.internal, processor: processor)
        ..end()
        ..setAttribute('late', true)
        ..addEvent('late-event')
        ..setStatus(StatusCode.error)
        ..end();

      final data = processor.ended.single;
      expect(data.attributes, isEmpty);
      expect(data.events, isEmpty);
      expect(data.statusCode, StatusCode.unset);
      expect(processor.ended, hasLength(1));
    });
  });
}
