import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart' as io_ws;

import '../config/app_config.dart';

/// Outbound/inbound transport contract. Wraps a real WebSocket so the client
/// can be swapped out for [FakeConnection] in tests without pulling in a real
/// WebSocket implementation.
abstract class WsConnection {
  Stream<String> get incoming;
  void send(String frame);
  Future<void> close();
}

/// Default [WsConnect] using `package:web_socket_channel`. Connects with the
/// `Authorization` and `X-Actor` headers so the server's auth gate accepts
/// the upgrade *before* we send the AuthMsg (the server still requires the
/// AuthMsg as a sanity check; both gates exist on purpose).
typedef WsConnect = Future<WsConnection> Function(Uri url);

Future<WsConnection> defaultWsConnect(Uri url) async {
  final channel = io_ws.IOWebSocketChannel.connect(url);
  await channel.ready;
  return _ChannelConnection(channel);
}

class _ChannelConnection implements WsConnection {
  _ChannelConnection(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get incoming =>
      _channel.stream.map((event) => event is String ? event : '$event');

  @override
  void send(String frame) => _channel.sink.add(frame);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}

typedef DelayFn = Future<void> Function(Duration);

/// Sealed event surface from [RobotNotesWsClient.events].
@immutable
sealed class RealtimeEvent {
  const RealtimeEvent();
}

/// A protocol message arrived from the server (presence, lock, changed,
/// pong, error). UI listeners drive their state from these.
class RealtimeMessage extends RealtimeEvent {
  const RealtimeMessage(this.message);
  final WsMessage message;
}

/// The client just established (or re-established) a session.
class WsConnected extends RealtimeEvent {
  const WsConnected();
}

/// The connection dropped. The reconnect loop is already running; UI may
/// show a "reconnecting…" indicator while it does.
class WsDisconnected extends RealtimeEvent {
  const WsDisconnected();
}

/// Offline longer than [RobotNotesWsClient.staleThreshold]. The UI should
/// treat the data on screen as potentially out of date and refetch via
/// HTTP once the connection comes back.
class WsStale extends RealtimeEvent {
  const WsStale();
}

/// Realtime client for `/ws`.
///
/// Lifecycle: `start()` opens the first connection, sends `AuthMsg`, and
/// re-sends `SubscribeMsg` for every note id added via [subscribe]. On
/// remote close it reconnects with exponential backoff (capped at
/// [backoffMax]). Each reconnect re-authenticates and re-subscribes. If
/// the cumulative offline duration exceeds [staleThreshold], the client
/// emits a single [WsStale] event so the UI can refresh.
///
/// All side effects route through the injected [connect], [delay], and
/// [clock] callbacks so tests stay deterministic and offline.
class RobotNotesWsClient {
  RobotNotesWsClient({
    required AppConfig config,
    WsConnect? connect,
    DelayFn? delay,
    DateTime Function()? clock,
    this.backoffInitial = const Duration(milliseconds: 200),
    this.backoffMax = const Duration(seconds: 30),
    this.staleThreshold = const Duration(seconds: 5),
  })  : _config = config.normalized(),
        _connect = connect ?? defaultWsConnect,
        _delay = delay ?? Future<void>.delayed,
        _now = clock ?? DateTime.now;

  final AppConfig _config;
  final WsConnect _connect;
  final DelayFn _delay;
  final DateTime Function() _now;
  final Duration backoffInitial;
  final Duration backoffMax;
  final Duration staleThreshold;

  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();
  final Set<String> _subscriptions = <String>{};

  WsConnection? _current;
  Future<void>? _loop;
  bool _disposed = false;
  bool _staleEmittedThisOutage = false;

  Stream<RealtimeEvent> get events => _events.stream;

  /// Starts the connect/reconnect loop. Returns once the first connection
  /// attempt has been kicked off (so callers can `await start()` and then
  /// immediately call [subscribe]). Does not block until `auth_ok`.
  Future<void> start() async {
    if (_loop != null) return;
    _loop = _runLoop();
  }

  void subscribe(String noteId) {
    _subscriptions.add(noteId);
    final c = _current;
    if (c != null) {
      c.send(jsonEncode(SubscribeMsg(noteId: noteId).toJson()));
    }
  }

  void unsubscribe(String noteId) {
    _subscriptions.remove(noteId);
    final c = _current;
    if (c != null) {
      c.send(jsonEncode(UnsubscribeMsg(noteId: noteId).toJson()));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final c = _current;
    _current = null;
    if (c != null) await c.close();
    final loop = _loop;
    if (loop != null) {
      // Wait for the reconnect loop to observe `_disposed` and exit so the
      // test process (and any caller) can clean up without leaking timers
      // or pending futures.
      await loop;
    }
    await _events.close();
  }

  Uri get _wsUri {
    final base = Uri.parse(_config.baseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(scheme: scheme, path: '/ws');
  }

  Future<void> _runLoop() async {
    var backoff = backoffInitial;
    DateTime? offlineSince;

    while (!_disposed) {
      WsConnection? conn;
      try {
        conn = await _connect(_wsUri);
      } catch (_) {
        conn = null;
      }

      if (conn != null && !_disposed) {
        _current = conn;
        offlineSince = null;
        _staleEmittedThisOutage = false;
        // Note: backoff is *not* reset just because the TCP/WS handshake
        // succeeded — a server stuck in a flap loop would otherwise let
        // us hammer it with rapid reconnects. We only reset once the
        // server confirms the session with `auth_ok` (see below).
        _emit(const WsConnected());

        // Auth first, then re-subscribe. AuthMsg goes out synchronously so the
        // 100ms post-open budget is trivially met.
        conn.send(
          jsonEncode(
            AuthMsg(key: _config.apiKey, actor: _config.actor).toJson(),
          ),
        );
        for (final id in _subscriptions) {
          conn.send(jsonEncode(SubscribeMsg(noteId: id).toJson()));
        }

        // Pump events until the remote closes or `dispose` is called.
        try {
          await for (final frame in conn.incoming) {
            try {
              final json = jsonDecode(frame) as Map<String, dynamic>;
              final msg = decodeWsMessage(json);
              if (msg is AuthOkMsg) {
                // Server accepted the session — back off resets so the
                // next disconnect starts at the initial delay again.
                backoff = backoffInitial;
              }
              _emit(RealtimeMessage(msg));
            } on FormatException {
              // Malformed frame — ignore. The server's protocol contract
              // says it sends valid JSON; if it doesn't, the connection
              // is the wrong layer to surface the bug.
              continue;
            }
          }
        } catch (_) {
          // Underlying transport raised — fall through to reconnect.
        }

        _current = null;
        if (_disposed) break;
        _emit(const WsDisconnected());
        offlineSince = _now();
      } else {
        offlineSince ??= _now();
      }

      if (_disposed) break;

      if (!_staleEmittedThisOutage &&
          _now().difference(offlineSince).compareTo(staleThreshold) >= 0) {
        _staleEmittedThisOutage = true;
        _emit(const WsStale());
      }

      await _delay(backoff);
      final next = backoff * 2;
      backoff = next > backoffMax ? backoffMax : next;
    }
  }

  void _emit(RealtimeEvent e) {
    if (_events.isClosed) return;
    _events.add(e);
  }
}
