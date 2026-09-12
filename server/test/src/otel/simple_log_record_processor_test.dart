import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/simple_log_record_processor.dart';
import 'package:test/test.dart';

class _FakeLogRecordExporter implements LogRecordExporter {
  final List<List<LogRecord>> exported = [];
  final List<OTelResource> resources = [];
  bool shutdownCalled = false;
  ExportResult result = const ExportResult.success();

  @override
  Future<ExportResult> export(
    List<LogRecord> records,
    OTelResource resource,
  ) async {
    exported.add(records);
    resources.add(resource);
    return result;
  }

  @override
  Future<void> shutdown() async {
    shutdownCalled = true;
  }
}

void main() {
  group('SimpleLogRecordProcessor', () {
    final resource = OTelResource(serviceName: 'test-service');

    test('exports each record immediately, one at a time', () async {
      final exporter = _FakeLogRecordExporter();
      final processor = SimpleLogRecordProcessor(exporter, resource)
        ..onEmit(LogRecord(body: 'first'))
        ..onEmit(LogRecord(body: 'second'));
      await processor.forceFlush();

      expect(exporter.exported, [
        [isA<LogRecord>().having((r) => r.body, 'body', 'first')],
        [isA<LogRecord>().having((r) => r.body, 'body', 'second')],
      ]);
      expect(exporter.resources, [resource, resource]);
    });

    test('forceFlush waits for in-flight export work', () async {
      final exporter = _FakeLogRecordExporter();
      final processor = SimpleLogRecordProcessor(exporter, resource)
        ..onEmit(LogRecord(body: 'x'));

      await processor.forceFlush();

      expect(exporter.exported, hasLength(1));
    });

    test('shutdown flushes and shuts down the exporter', () async {
      final exporter = _FakeLogRecordExporter();
      final processor = SimpleLogRecordProcessor(exporter, resource)
        ..onEmit(LogRecord(body: 'x'));
      await processor.shutdown();

      expect(exporter.exported, hasLength(1));
      expect(exporter.shutdownCalled, isTrue);
    });

    test('drops records emitted after shutdown', () async {
      final exporter = _FakeLogRecordExporter();
      final processor = SimpleLogRecordProcessor(exporter, resource);

      await processor.shutdown();
      processor.onEmit(LogRecord(body: 'too late'));
      await processor.forceFlush();

      expect(exporter.exported, isEmpty);
    });
  });
}
