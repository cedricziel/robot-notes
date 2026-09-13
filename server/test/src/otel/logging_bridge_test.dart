import 'dart:async';

import 'package:flutter_otel_api/flutter_otel_api.dart' as otel;
import 'package:flutter_otel_sdk/flutter_otel_sdk.dart' show SdkTracer;
import 'package:logging/logging.dart' as logging;
import 'package:server/src/otel/logging_bridge.dart';
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

/// Minimal test-only [otel.LoggerProvider]: stamps each vended logger's
/// scope onto every record before forwarding it to a shared processor.
/// Mirrors what `otel_bootstrap.dart` gets from `SdkLoggerProvider` in
/// production, without pulling in its resource/session-manager plumbing.
class _TestLoggerProvider implements otel.LoggerProvider {
  _TestLoggerProvider(this._processor);

  final otel.LogRecordProcessor _processor;

  @override
  otel.Logger getLogger({
    String name = otel.defaultInstrumentationScopeName,
    String? version,
  }) =>
      _ScopedLogger(_processor, name, version);

  @override
  void ingestLogRecord(otel.LogRecord record) => _processor.onEmit(record);

  @override
  Future<void> forceFlush() => _processor.forceFlush();

  @override
  Future<void> shutdown() => _processor.shutdown();
}

class _ScopedLogger extends otel.Logger {
  _ScopedLogger(this._processor, this._name, this._version);

  final otel.LogRecordProcessor _processor;
  final String _name;
  final String? _version;

  @override
  void emit(otel.LogRecord record) =>
      _processor.onEmit(record.withScope(_name, _version));
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
      final provider = _TestLoggerProvider(processor);
      subscription = installOtelLoggingBridge(provider);

      namedLogger.info('hello world');
      await Future<void>.delayed(Duration.zero);

      expect(processor.emitted, hasLength(1));
      final record = processor.emitted.single;
      expect(record.body, 'hello world');
      expect(record.scopeName, 'bridge_test');
      expect(record.severity, otel.LogSeverity.info);
    });

    test('has no traceId/spanId when there is no active span', () async {
      final processor = _FakeLogRecordProcessor();
      final provider = _TestLoggerProvider(processor);
      subscription = installOtelLoggingBridge(provider);

      namedLogger.info('no span here');
      await Future<void>.delayed(Duration.zero);

      final record = processor.emitted.single;
      expect(record.traceId, isNull);
      expect(record.spanId, isNull);
    });

    test('attaches traceId/spanId from the span active when logged', () async {
      final processor = _FakeLogRecordProcessor();
      final provider = _TestLoggerProvider(processor);
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
      expect(record.traceId, span.spanContext.traceId);
      expect(record.spanId, span.spanContext.spanId);
    });

    test('carries error and stackTrace as attributes', () async {
      final processor = _FakeLogRecordProcessor();
      final provider = _TestLoggerProvider(processor);
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
        final provider = _TestLoggerProvider(processor);
        subscription = installOtelLoggingBridge(provider);

        namedLogger.log(entry.key, 'msg');
        await Future<void>.delayed(Duration.zero);

        expect(processor.emitted.single.severity, entry.value);
      });
    }
  });
}
