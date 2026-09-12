import 'dart:async';
import 'dart:io';

import 'package:flutter_otel_api/flutter_otel_api.dart';

/// A [LogRecordProcessor] that exports every record immediately, one at a
/// time. Mirrors `flutter_otel_sdk`'s `SimpleLogRecordProcessor`, but logs
/// export failures to [stderr] instead of `package:flutter/foundation.dart`'s
/// `debugPrint`, since this server has no Flutter SDK to depend on.
class SimpleLogRecordProcessor implements LogRecordProcessor {
  /// Creates a processor exporting every emitted record through [exporter],
  /// stamped with [resource].
  SimpleLogRecordProcessor(this.exporter, this.resource);

  /// The exporter each emitted record is sent to, one at a time.
  final LogRecordExporter exporter;

  /// The resource attached to every export call.
  final OTelResource resource;

  final List<Future<void>> _pending = [];
  bool _shutdown = false;

  @override
  void onEmit(LogRecord record) {
    if (_shutdown) return;
    final future = _exportSafely([record]);
    _pending.add(future);
    unawaited(future.whenComplete(() => _pending.remove(future)));
  }

  Future<void> _exportSafely(List<LogRecord> records) async {
    try {
      final result = await exporter.export(records, resource);
      if (!result.success) {
        stderr.writeln('otel: log export failed: ${result.error}');
      }
    } catch (e, stackTrace) {
      stderr.writeln('otel: log export threw: $e\n$stackTrace');
    }
  }

  @override
  Future<void> forceFlush() => Future.wait(List<Future<void>>.of(_pending));

  @override
  Future<void> shutdown() async {
    _shutdown = true;
    await forceFlush();
    await exporter.shutdown();
  }
}
