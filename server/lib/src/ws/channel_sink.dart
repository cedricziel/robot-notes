import 'dart:io';

import 'package:server/src/ws/connection.dart';

/// Adapts a native [WebSocket] to the [WsSink] interface used by
/// [WsConnection]. The route handler instantiates one per upgraded
/// connection so the state machine never depends on a real socket.
class ChannelWsSink implements WsSink {
  /// Wraps [_socket] so [WsConnection] can write text frames and request
  /// closes through it.
  ChannelWsSink(this._socket);

  final WebSocket _socket;
  bool _closed = false;

  @override
  void send(String data) {
    if (_closed) return;
    _socket.add(data);
  }

  @override
  void close(int code, String reason) {
    if (_closed) return;
    _closed = true;
    _socket.close(code, reason);
  }

  @override
  bool get isClosed => _closed;
}
