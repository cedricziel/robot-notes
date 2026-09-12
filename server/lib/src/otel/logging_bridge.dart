import 'dart:async';

import 'package:flutter_otel_api/flutter_otel_api.dart' as otel;
import 'package:logging/logging.dart' as logging;

/// Forwards every `package:logging` record emitted anywhere in the process
/// to an otel [otel.LoggerProvider], so the ~15 existing `Logger('...')`
/// call sites across the server get exported without any per-call-site
/// changes. Returns the underlying subscription so callers can cancel it.
StreamSubscription<logging.LogRecord> installOtelLoggingBridge(
  otel.LoggerProvider provider,
) =>
    logging.Logger.root.onRecord.listen((record) {
      provider
          .getLogger(name: record.loggerName)
          .emit(_toOtelRecord(record, _activeSpan(record)));
    });

/// Resolves the [otel.Span] that was active when [record] was created, or
/// `null` if none was.
///
/// `Logger.log()` captures `Zone.current` into [logging.LogRecord.zone] at
/// record-construction time — but this bridge's `onRecord.listen` callback
/// always runs in the zone active when [installOtelLoggingBridge] was
/// called (process startup), not the zone that emitted the record: Dart
/// binds a stream listener callback to its registration-time zone, even
/// for a `sync: true` controller (verified: emitting inside a zone that
/// sets a zone value does not make that value visible to `Zone.current`
/// inside the listener). Re-entering the captured zone via [Zone.run]
/// restores that visibility for the duration of this call, letting
/// [otel.Span.current] resolve the request's span correctly regardless of
/// which zone the listener itself runs in.
otel.Span? _activeSpan(logging.LogRecord record) =>
    record.zone?.run(() => otel.Span.current);

otel.LogRecord _toOtelRecord(logging.LogRecord record, otel.Span? span) =>
    otel.LogRecord(
      body: record.message,
      severity: _severityFor(record.level),
      timestamp: record.time,
      attributes: {
        if (span != null) 'trace_id': span.spanContext.traceId,
        if (span != null) 'span_id': span.spanContext.spanId,
        if (record.error != null)
          'exception.type': record.error.runtimeType.toString(),
        if (record.error != null) 'exception.message': record.error.toString(),
        if (record.stackTrace != null)
          'exception.stacktrace': record.stackTrace.toString(),
      },
    );

otel.LogSeverity _severityFor(logging.Level level) {
  if (level >= logging.Level.SHOUT) return otel.LogSeverity.fatal;
  if (level >= logging.Level.SEVERE) return otel.LogSeverity.error;
  if (level >= logging.Level.WARNING) return otel.LogSeverity.warn;
  if (level >= logging.Level.INFO) return otel.LogSeverity.info;
  if (level >= logging.Level.FINE) return otel.LogSeverity.debug;
  return otel.LogSeverity.trace;
}
