import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor_middleware.dart';
import 'package:server/src/auth_middleware.dart';
import 'package:server/src/config.dart';
import 'package:server/src/config_holder.dart' as config_holder;

/// Root route middleware applied to every request.
///
/// Order is bottom-up (last `.use` runs first):
///   1. `provider<Config>` so handlers and downstream middleware can
///      `read<Config>()`.
///   2. [bearerAuth] gates traffic on the configured API key (with
///      `GET /healthz` exempted inside the middleware).
///   3. [actorIdentity] derives the display actor from `X-Actor` and
///      provides it via `context.read<Actor>()`. This runs after auth so
///      we never expose an actor to a handler that wouldn't otherwise
///      execute.
Handler middleware(Handler handler) {
  final config = config_holder.config;
  return handler
      .use(actorIdentity())
      .use(bearerAuth(configuredKey: config.apiKey))
      .use(provider<Config>((_) => config));
}
