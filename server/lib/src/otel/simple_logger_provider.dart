import 'package:flutter_otel_api/flutter_otel_api.dart';

/// A [LoggerProvider] that vends [Logger]s stamping records with their
/// requested instrumentation scope before forwarding them to a single
/// shared [LogRecordProcessor].
class SimpleLoggerProvider implements LoggerProvider {
  /// Creates a provider whose loggers all forward emitted records to the
  /// given processor.
  SimpleLoggerProvider(this._processor);

  final LogRecordProcessor _processor;
  final Map<(String, String?), _ScopedLogger> _loggers = {};

  @override
  Logger getLogger({
    String name = defaultInstrumentationScopeName,
    String? version,
  }) =>
      _loggers.putIfAbsent(
        (name, version),
        () => _ScopedLogger(_processor, name, version),
      );

  @override
  void ingestLogRecord(LogRecord record) => _processor.onEmit(record);

  @override
  Future<void> forceFlush() => _processor.forceFlush();

  @override
  Future<void> shutdown() => _processor.shutdown();
}

class _ScopedLogger extends Logger {
  _ScopedLogger(this._processor, this._name, this._version);

  final LogRecordProcessor _processor;
  final String _name;
  final String? _version;

  @override
  void emit(LogRecord record) =>
      _processor.onEmit(record.withScope(_name, _version));
}
