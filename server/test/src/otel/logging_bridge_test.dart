import 'dart:async';

import 'package:flutter_otel_api/flutter_otel_api.dart' as otel;
import 'package:logging/logging.dart' as logging;
import 'package:server/src/otel/logging_bridge.dart';
import 'package:server/src/otel/sdk_tracer.dart';
import 'package:server/src/otel/simple_logger_provider.dart';
import 'package:test/test.dart';

class _FakeLogRecordProcessor implements otel.LogRecordProcessor {
  final List<otel.LogRecord> emitted = [];

  @override
  void onEmit(otel.LogRecord record) => emitted.add(record);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

class _NoopSpanProcessor implements otel.SpanProcessor {
  @override
  void onEnd(otel.SpanData span) {}

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

void main() {
  group('installOtelLoggingBridge', () {
    late logging.Logger namedLogger;
    StreamSubscription<logging.LogRecord>? subscription;

    setUp(() {
      namedLogger = logging.Logger('bridge_test');
      logging.Logger.root.level = logging.Level.ALL;
    });

    tearDown(() async {
      await subscription?.cancel();
    });

    test('forwards an INFO record with the logger name as scope', () async {
      final processor = _FakeLogRecordProcessor();
      final provider = SimpleLoggerProvider(processor);
      subscription = installOtelLoggingBridge(provider);

      namedLogger.info('hello world');
      await Future<void>.delayed(Duration.zero);

      expect(processor.emitted, hasLength(1));
      final record = processor.emitted.single;
      expect(record.body, 'hello world');
      expect(record.scopeName, 'bridge_test');
      expect(record.severity, otel.LogSeverity.info);
    });

    test('has no trace_id/span_id attributes when there is no active span',
        () async {
      final processor = _FakeLogRecordProcessor();
      final provider = SimpleLoggerProvider(processor);
      subscription = installOtelLoggingBridge(provider);

      namedLogger.info('no span here');
      await Future<void>.delayed(Duration.zero);

      final record = processor.emitted.single;
      expect(record.attributes.containsKey('trace_id'), isFalse);
      expect(record.attributes.containsKey('span_id'), isFalse);
    });

    test('attaches trace_id/span_id from the span active when logged',
        () async {
      final processor = _FakeLogRecordProcessor();
      final provider = SimpleLoggerProvider(processor);
      subscription = installOtelLoggingBridge(provider);
      final tracer = SdkTracer(
        name: 'test',
        version: null,
        processor: _NoopSpanProcessor(),
      );
      final span = tracer.startSpan('request');

      await otel.Span.runWithSpan(span, () async {
        namedLogger.info('inside a span');
      });
      await Future<void>.delayed(Duration.zero);

      final record = processor.emitted.single;
      expect(record.attributes['trace_id'], span.spanContext.traceId);
      expect(record.attributes['span_id'], span.spanContext.spanId);
    });

    test('carries error and stackTrace as attributes', () async {
      final processor = _FakeLogRecordProcessor();
      final provider = SimpleLoggerProvider(processor);
      subscription = installOtelLoggingBridge(provider);

      final stackTrace = StackTrace.current;
      namedLogger.severe('boom', StateError('bad'), stackTrace);
      await Future<void>.delayed(Duration.zero);

      final record = processor.emitted.single;
      expect(record.severity, otel.LogSeverity.error);
      expect(record.attributes['exception.type'], 'StateError');
      expect(record.attributes['exception.message'], contains('bad'));
      expect(record.attributes['exception.stacktrace'], stackTrace.toString());
    });

    for (final entry in {
      logging.Level.FINEST: otel.LogSeverity.trace,
      logging.Level.FINER: otel.LogSeverity.trace,
      logging.Level.FINE: otel.LogSeverity.debug,
      logging.Level.CONFIG: otel.LogSeverity.debug,
      logging.Level.INFO: otel.LogSeverity.info,
      logging.Level.WARNING: otel.LogSeverity.warn,
      logging.Level.SEVERE: otel.LogSeverity.error,
      logging.Level.SHOUT: otel.LogSeverity.fatal,
    }.entries) {
      test('maps ${entry.key} to ${entry.value}', () async {
        final processor = _FakeLogRecordProcessor();
        final provider = SimpleLoggerProvider(processor);
        subscription = installOtelLoggingBridge(provider);

        namedLogger.log(entry.key, 'msg');
        await Future<void>.delayed(Duration.zero);

        expect(processor.emitted.single.severity, entry.value);
      });
    }
  });
}
