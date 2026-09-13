import 'dart:async';

import 'package:dart_frog/dart_frog.dart';
import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/config.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:server/src/otel/otel_tracer_holder.dart' as otel_tracer_holder;
import 'package:server/src/public_url.dart';
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
  final tokenStore = context.read<TokenStore>();
  final restResource = publicBaseUrl(context);
  final tracer = otel_tracer_holder.otelTracerProvider.getTracer(
    name: 'robot-notes-server',
  );
  // Captured while this handler still runs inside otelHttpTraceMiddleware's
  // span (see connection.dart's handleMessage doc for why messages don't
  // simply nest under it instead).
  final upgradeSpanContext = Span.current?.spanContext;
  final connectionSpanContext =
      upgradeSpanContext != null && upgradeSpanContext.isValid
          ? upgradeSpanContext
          : null;

  final handler = webSocketHandler((channel, _) {
    final id = Ulid().toString();
    final sink = ChannelWsSink(channel);
    final conn = WsConnection(
      id: id,
      sink: sink,
      broadcaster: broadcaster,
      presence: presence,
      apiKey: apiKey,
      tokenStore: tokenStore,
      restResource: restResource,
      tracer: tracer,
      connectionSpanContext: connectionSpanContext,
    )..start();

    // Auth may now require an async token-store lookup; pause delivery of
    // further frames while one message is still being handled so a
    // `subscribe` sent immediately after `auth` can never be evaluated
    // before the auth message it depends on has finished.
    late final StreamSubscription<dynamic> sub;
    sub = channel.stream.listen(
      (data) {
        sub.pause();
        unawaited(
          conn.handleMessage(data).whenComplete(sub.resume),
        );
      },
      onDone: () {
        unawaited(sub.cancel());
        conn.handleDone();
      },
      cancelOnError: true,
    );
  });

  return handler(context);
}
