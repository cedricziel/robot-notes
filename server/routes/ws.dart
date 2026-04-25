import 'dart:async';

import 'package:dart_frog/dart_frog.dart';
import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:server/src/config.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/channel_sink.dart';
import 'package:server/src/ws/connection.dart';
import 'package:server/src/ws/presence.dart';
import 'package:ulid/ulid.dart';

/// `GET /ws` — upgrades to a WebSocket and runs the v1 robot-notes protocol.
///
/// HTTP-level bearer auth is bypassed for this path (browsers can't set
/// arbitrary headers on the upgrade request); the WS protocol does its own
/// auth via the first `auth` envelope, with a 2s timeout enforced by
/// [WsConnection].
FutureOr<Response> onRequest(RequestContext context) {
  final broadcaster = context.read<Broadcaster>();
  final presence = context.read<PresenceTracker>();
  final apiKey = context.read<Config>().apiKey;

  final handler = webSocketHandler((channel, _) {
    final id = Ulid().toString();
    final sink = ChannelWsSink(channel);
    final conn = WsConnection(
      id: id,
      sink: sink,
      broadcaster: broadcaster,
      presence: presence,
      apiKey: apiKey,
    )..start();

    channel.stream.listen(
      conn.handleMessage,
      onDone: conn.handleDone,
      cancelOnError: true,
    );
  });

  return handler(context);
}
