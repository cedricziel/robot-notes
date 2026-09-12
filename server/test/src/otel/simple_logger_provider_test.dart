import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/simple_logger_provider.dart';
import 'package:test/test.dart';

class _FakeLogRecordProcessor implements LogRecordProcessor {
  final List<LogRecord> emitted = [];
  bool flushCalled = false;
  bool shutdownCalled = false;

  @override
  void onEmit(LogRecord record) => emitted.add(record);

  @override
  Future<void> forceFlush() async => flushCalled = true;

  @override
  Future<void> shutdown() async => shutdownCalled = true;
}

void main() {
  group('SimpleLoggerProvider', () {
    test('getLogger returns a Logger that stamps the requested scope', () {
      final processor = _FakeLogRecordProcessor();
      final provider = SimpleLoggerProvider(processor);

      provider.getLogger(name: 'my_scope', version: '1.0').info('hello');

      expect(processor.emitted, hasLength(1));
      expect(processor.emitted.single.scopeName, 'my_scope');
      expect(processor.emitted.single.scopeVersion, '1.0');
      expect(processor.emitted.single.body, 'hello');
    });

    test('returns the same Logger instance for the same scope name', () {
      final processor = _FakeLogRecordProcessor();
      final provider = SimpleLoggerProvider(processor);

      final a = provider.getLogger(name: 'scope');
      final b = provider.getLogger(name: 'scope');

      expect(identical(a, b), isTrue);
    });

    test('forceFlush delegates to the processor', () async {
      final processor = _FakeLogRecordProcessor();
      final provider = SimpleLoggerProvider(processor);

      await provider.forceFlush();

      expect(processor.flushCalled, isTrue);
    });

    test('shutdown delegates to the processor', () async {
      final processor = _FakeLogRecordProcessor();
      final provider = SimpleLoggerProvider(processor);

      await provider.shutdown();

      expect(processor.shutdownCalled, isTrue);
    });
  });
}
