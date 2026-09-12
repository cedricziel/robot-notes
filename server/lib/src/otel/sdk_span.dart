import 'dart:math';

import 'package:flutter_otel_api/flutter_otel_api.dart';

final Random _random = Random.secure();

String _randomHex(int byteLength) {
  final bytes = List<int>.generate(byteLength, (_) => _random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// Generates a fresh 32-hex-character trace ID.
String generateTraceId() => _randomHex(16);

/// Generates a fresh 16-hex-character span ID.
String generateSpanId() => _randomHex(8);

/// Concrete [Span] implementation. Mirrors `flutter_otel_sdk`'s `SdkSpan`,
/// ported here because that package depends on the Flutter SDK, which this
/// Dart Frog server doesn't have (see `simple_log_record_processor.dart` for
/// the same rationale on the logs side).
///
/// Generates its own span ID; the trace ID comes from a parent context when
/// given (this span joins that trace), or is freshly generated if this is a
/// root span. `end()` snapshots this span and hands it to its processor;
/// calling `end()` more than once is a safe no-op.
class SdkSpan implements Span {
  /// Creates a span, resolving its trace ID from [parentContext] (or
  /// generating a fresh one for a root span) and forwarding the finished
  /// snapshot to [processor] on [end].
  SdkSpan({
    required this.name,
    required SpanKind kind,
    required SpanProcessor processor,
    SpanContext? parentContext,
    this.parentSpanId,
    DateTime? startTime,
    Map<String, Object?>? attributes,
    this.scopeName = defaultInstrumentationScopeName,
    this.scopeVersion,
  })  : _kind = kind,
        _processor = processor,
        _startTime = startTime ?? DateTime.now(),
        _attributes = {...?attributes},
        spanContext = SpanContext(
          traceId: parentContext?.traceId ?? generateTraceId(),
          spanId: generateSpanId(),
        );

  @override
  final String name;

  @override
  final SpanContext spanContext;

  /// The hex-encoded span ID of this span's parent, or `null` for a root
  /// span.
  final String? parentSpanId;

  /// The instrumentation scope (tracer) name this span was created under.
  final String scopeName;

  /// The instrumentation scope (tracer) version this span was created
  /// under, if any.
  final String? scopeVersion;

  final SpanKind _kind;
  final SpanProcessor _processor;
  final DateTime _startTime;
  final Map<String, Object?> _attributes;
  final List<SpanEvent> _events = [];
  StatusCode _statusCode = StatusCode.unset;
  String? _statusDescription;
  bool _ended = false;

  @override
  bool get isRecording => !_ended;

  @override
  void setAttribute(String key, Object? value) {
    if (_ended) return;
    _attributes[key] = value;
  }

  @override
  void setAttributes(Map<String, Object?> attributes) {
    if (_ended) return;
    _attributes.addAll(attributes);
  }

  @override
  void addEvent(
    String name, {
    Map<String, Object?>? attributes,
    DateTime? timestamp,
  }) {
    if (_ended) return;
    _events.add(
      SpanEvent(
        name: name,
        timestamp: timestamp,
        attributes: attributes ?? const {},
      ),
    );
  }

  @override
  void setStatus(StatusCode code, {String? description}) {
    if (_ended) return;
    _statusCode = code;
    _statusDescription = description;
  }

  @override
  void recordException(
    Object exception, {
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {
    if (_ended) return;
    addEvent(
      'exception',
      attributes: {
        'exception.type': exception.runtimeType.toString(),
        'exception.message': exception.toString(),
        if (stackTrace != null) 'exception.stacktrace': stackTrace.toString(),
        ...?attributes,
      },
    );
  }

  @override
  void end([DateTime? endTime]) {
    if (_ended) return;
    _ended = true;
    final data = SpanData(
      name: name,
      spanContext: spanContext,
      parentSpanId: parentSpanId,
      kind: _kind,
      startTime: _startTime,
      endTime: endTime ?? DateTime.now(),
      attributes: _attributes,
      events: _events,
      statusCode: _statusCode,
      statusDescription: _statusDescription,
      scopeName: scopeName,
      scopeVersion: scopeVersion,
    );
    _processor.onEnd(data);
  }
}
