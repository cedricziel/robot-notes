import 'dart:async';

import 'package:dart_otel_api/dart_otel_api.dart' as otel;
import 'package:logging/logging.dart' as logging;

/// Forwards every `package:logging` record emitted anywhere in the app to
/// an otel [otel.LoggerProvider], so existing/future `Logger('...')` call
/// sites get exported without any per-call-site changes. Returns the
/// underlying subscription so callers can cancel it.
StreamSubscription<logging.LogRecord> installOtelLoggingBridge(
  otel.LoggerProvider provider,
) => logging.Logger.root.onRecord.listen((record) {
  provider.getLogger(name: record.loggerName).emit(_toOtelRecord(record));
});

otel.LogRecord _toOtelRecord(logging.LogRecord record) => otel.LogRecord(
  body: record.message,
  severity: _severityFor(record.level),
  timestamp: record.time,
  attributes: {
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
