import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';
import 'package:shared/shared.dart';

/// Default time a freshly-opened WebSocket has to send its first auth message
/// before the server closes it with `auth_timeout`.
const Duration kDefaultWsAuthTimeout = Duration(seconds: 2);

/// WebSocket close code used for auth failures (timeout, wrong key, etc.).
/// Lives in the application range [4000, 4999].
const int kCloseAuthFailure = 4001;

/// WebSocket close code for "unsupported data" — sent when the client pushes
/// a binary frame, which the v1 protocol does not accept.
const int kCloseUnsupportedData = 1003;

/// WebSocket close code for "policy violation" — sent when an authed
/// connection's outbox grows past the slow-consumer threshold.
const int kClosePolicyViolation = 1008;

/// Adapter that the [WsConnection] writes through. Real WebSocket channels
/// are wrapped via the route handler; tests inject a fake sink.
abstract class WsSink {
  /// Sends a UTF-8 text frame.
  void send(String data);

  /// Closes the underlying socket with [code] / [reason]. Must be idempotent.
  void close(int code, String reason);

  /// True after [close] has been invoked.
  bool get isClosed;
}

/// Per-connection state machine that handles the v1 `/ws` protocol.
///
/// The connection starts in `connecting` state and ignores everything until
/// it sees a valid `auth` envelope. After auth, it forwards subscribed
/// events from the [Broadcaster], maintains presence membership through
/// [PresenceTracker], echoes pings, and surfaces unknown-type messages as
/// in-band `error` envelopes without closing the socket.
///
/// A connection can be closed for three reasons:
///   1. The auth timer fired before any auth message arrived.
///   2. The client supplied the wrong API key.
///   3. The client sent a binary frame (the v1 protocol is text-only).
///   4. The server-side outbox exceeded the slow-consumer threshold.
class WsConnection {
  /// Creates a state machine. The caller is responsible for invoking
  /// [start], [handleMessage], and [handleDone] in response to events on
  /// the underlying socket.
  WsConnection({
    required this.id,
    required WsSink sink,
    required Broadcaster broadcaster,
    required PresenceTracker presence,
    required String apiKey,
    Duration authTimeout = kDefaultWsAuthTimeout,
    Logger? logger,
  })  : _sink = sink,
        _broadcaster = broadcaster,
        _presence = presence,
        _apiKey = apiKey,
        _authTimeout = authTimeout,
        _log = logger ?? Logger('ws_connection');

  /// Unique connection identifier — must be stable for the connection's
  /// lifetime so the broadcaster and presence tracker can correlate.
  final String id;

  final WsSink _sink;
  final Broadcaster _broadcaster;
  final PresenceTracker _presence;
  final String _apiKey;
  final Duration _authTimeout;
  final Logger _log;

  Timer? _authTimer;
  StreamSubscription<WsMessage>? _bcastSub;
  Actor? _actor;
  bool _closed = false;

  /// True once the auth handshake has succeeded and before the connection
  /// has been closed.
  bool get isAuthed => _actor != null && !_closed;

  /// True after the underlying socket has been closed (locally or remotely).
  bool get isClosed => _closed;

  /// Bound display identity, or `null` while the connection is pre-auth.
  Actor? get actor => _actor;

  /// Starts the auth timer. Calling start more than once is a programmer
  /// error (the manager should construct a fresh connection per socket).
  void start() {
    _authTimer = Timer(_authTimeout, _handleAuthTimeout);
  }

  /// Feeds an inbound socket frame into the state machine. Strings are
  /// parsed as JSON envelopes; any other type (typically binary data) is
  /// treated as a protocol violation and the connection is closed.
  void handleMessage(Object? data) {
    if (_closed) return;
    if (data is! String) {
      _close(kCloseUnsupportedData, 'unsupported_data');
      return;
    }
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) {
        _sendError(ErrorCode.unknownType, received: data);
        return;
      }
      json = decoded;
    } on FormatException {
      _sendError(ErrorCode.unknownType, received: data);
      return;
    }
    if (!isAuthed) {
      _handleConnectingMessage(json, raw: data);
    } else {
      _handleAuthedMessage(json, raw: data);
    }
  }

  /// Called when the underlying socket signals close. Cleans up presence,
  /// the broadcaster registration, and any outstanding timers.
  Future<void> handleDone() async {
    if (_closed) return;
    _closed = true;
    _authTimer?.cancel();
    _authTimer = null;
    final events = _presence.disconnect(id);
    for (final ev in events.values) {
      _broadcaster.emitPresence(ev);
    }
    await _bcastSub?.cancel();
    _bcastSub = null;
    await _broadcaster.disconnect(id);
  }

  // ---------- internals ----------

  void _handleAuthTimeout() {
    if (isAuthed || _closed) return;
    _log.fine('auth_timeout for $id');
    _close(kCloseAuthFailure, ErrorCode.authTimeout.wire);
  }

  void _handleConnectingMessage(
    Map<String, dynamic> json, {
    required String raw,
  }) {
    final type = json['type'];
    if (type != 'auth') {
      // Pre-auth: any non-auth message is silently ignored per the spec.
      return;
    }
    final AuthMsg msg;
    try {
      msg = AuthMsg.fromJson(json);
    } on Object {
      _sendError(ErrorCode.unknownType, received: raw);
      return;
    }
    if (msg.key != _apiKey) {
      _log.fine('auth_failed for $id (bad key)');
      _close(kCloseAuthFailure, ErrorCode.authFailed.wire);
      return;
    }
    _authTimer?.cancel();
    _authTimer = null;
    _actor = Actor.fromHeader(msg.actor);
    _send(const AuthOkMsg());
    _attachBroadcaster();
    _log.fine('auth_ok for $id as ${_actor!.name}');
  }

  void _handleAuthedMessage(
    Map<String, dynamic> json, {
    required String raw,
  }) {
    final type = json['type'];
    switch (type) {
      case 'subscribe':
        _handleSubscribe(SubscribeMsg.fromJson(json));
      case 'unsubscribe':
        _handleUnsubscribe(UnsubscribeMsg.fromJson(json));
      case 'ping':
        final ping = PingMsg.fromJson(json);
        _send(PongMsg(id: ping.id));
      case 'auth':
        // Re-auth is not supported in v1; ignore but keep the connection.
        return;
      default:
        _sendError(ErrorCode.unknownType, received: raw);
    }
  }

  void _handleSubscribe(SubscribeMsg msg) {
    final actor = _actor!;
    if (msg.noteId == '*') {
      _broadcaster.subscribeWildcard(id);
      return;
    }
    _broadcaster.subscribe(id, msg.noteId);
    final ev = _presence.add(id, actor.name, msg.noteId);
    if (ev != null) _broadcaster.emitPresence(ev);
  }

  void _handleUnsubscribe(UnsubscribeMsg msg) {
    if (msg.noteId == '*') {
      // Wildcard removal isn't part of v1 — clients reconnect to reset.
      return;
    }
    _broadcaster.unsubscribe(id, msg.noteId);
    final ev = _presence.remove(id, msg.noteId);
    if (ev != null) _broadcaster.emitPresence(ev);
  }

  void _attachBroadcaster() {
    final stream = _broadcaster.register(id);
    _bcastSub = stream.listen(
      _forward,
      onDone: () {
        // Broadcaster closed our stream — this means we were dropped or
        // the server is shutting down. Close the socket if we haven't
        // already done so.
        if (!_closed) _close(kClosePolicyViolation, 'broadcaster_closed');
      },
    );
  }

  void _forward(WsMessage msg) {
    if (_closed) return;
    _sink.send(jsonEncode(msg.toJson()));
  }

  void _send(WsMessage msg) {
    if (_closed) return;
    _sink.send(jsonEncode(msg.toJson()));
  }

  void _sendError(ErrorCode code, {String? received}) {
    if (_closed) return;
    _sink.send(jsonEncode(ErrorMsg(code: code, received: received).toJson()));
  }

  void _close(int code, String reason) {
    if (_closed) return;
    _closed = true;
    _authTimer?.cancel();
    _authTimer = null;
    _sink.close(code, reason);
    // Best-effort cleanup; handleDone() may also be invoked by the route.
    final events = _presence.disconnect(id);
    for (final ev in events.values) {
      _broadcaster.emitPresence(ev);
    }
    unawaited(_bcastSub?.cancel());
    _bcastSub = null;
    unawaited(_broadcaster.disconnect(id));
  }

  /// Test hook: returns true while the auth timer is still scheduled.
  bool get authTimerArmed => _authTimer != null;
}
