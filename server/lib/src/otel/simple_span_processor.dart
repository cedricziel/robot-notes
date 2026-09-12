import 'dart:async';
import 'dart:io';

import 'package:flutter_otel_api/flutter_otel_api.dart';

/// A [SpanProcessor] that exports every finished span immediately, one at a
/// time. Mirrors `flutter_otel_sdk`'s `SimpleSpanProcessor`, but logs export
/// failures to [stderr] instead of `package:flutter/foundation.dart`'s
/// `debugPrint`, since this server has no Flutter SDK to depend on.
class SimpleSpanProcessor implements SpanProcessor {
  /// Creates a processor exporting every ended span through [exporter],
  /// stamped with [resource].
  SimpleSpanProcessor(this.exporter, this.resource);

  /// The exporter each ended span is sent to, one at a time.
  final SpanExporter exporter;

  /// The resource attached to every export call.
  final OTelResource resource;

  final List<Future<void>> _pending = [];
  bool _shutdown = false;

  @override
  void onEnd(SpanData span) {
    if (_shutdown) return;
    final future = _exportSafely([span]);
    _pending.add(future);
    unawaited(future.whenComplete(() => _pending.remove(future)));
  }

  Future<void> _exportSafely(List<SpanData> spans) async {
    try {
      final result = await exporter.export(spans, resource);
      if (!result.success) {
        stderr.writeln('otel: span export failed: ${result.error}');
      }
    } catch (e, stackTrace) {
      stderr.writeln('otel: span export threw: $e\n$stackTrace');
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
