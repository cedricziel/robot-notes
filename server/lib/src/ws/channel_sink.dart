import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:server/src/ws/connection.dart';

/// Adapts a [WebSocketChannel] to the [WsSink] interface used by
/// [WsConnection]. The route handler instantiates one per upgraded
/// connection so the state machine never depends on a real socket.
class ChannelWsSink implements WsSink {
  /// Wraps [_channel] so [WsConnection] can write text frames and request
  /// closes through it.
  ChannelWsSink(this._channel);

  final WebSocketChannel _channel;
  bool _closed = false;

  @override
  void send(String data) {
    if (_closed) return;
    _channel.sink.add(data);
  }

  @override
  void close(int code, String reason) {
    if (_closed) return;
    _closed = true;
    _channel.sink.close(code, reason);
  }

  @override
  bool get isClosed => _closed;
}
