import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor_middleware.dart';
import 'package:server/src/app_deps_holder.dart' as app_deps_holder;
import 'package:server/src/auth_middleware.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/config_holder.dart' as config_holder;
import 'package:server/src/invite_store.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';

/// Root route middleware applied to every request.
///
/// Order is bottom-up (last `.use` runs first):
///   1. `provider<Config>` and the long-lived dependency providers
///      ([Storage], [MetaIndex], [LockManager], [Broadcaster],
///      [PresenceTracker]) so handlers and downstream middleware can
///      `read<T>()` them.
///   2. [bearerAuth] gates traffic on the configured API key (with
///      `GET /healthz` exempted inside the middleware).
///   3. [actorIdentity] derives the display actor from `X-Actor` and
///      provides it via `context.read<Actor>()`. This runs after auth so
///      we never expose an actor to a handler that wouldn't otherwise
///      execute.
Handler middleware(Handler handler) {
  final config = config_holder.config;
  final deps = app_deps_holder.appDeps;
  return handler
      .use(actorIdentity())
      .use(bearerAuth(configuredKey: config.apiKey))
      .use(provider<PresenceTracker>((_) => deps.presence))
      .use(provider<Broadcaster>((_) => deps.broadcaster))
      .use(provider<LockManager>((_) => deps.lockManager))
      .use(provider<SearchIndex>((_) => deps.searchIndex))
      .use(provider<InviteStore>((_) => deps.inviteStore))
      .use(provider<MetaIndex>((_) => deps.metaIndex))
      .use(provider<NoteWriteService>((_) => deps.noteWriteService))
      .use(provider<Storage>((_) => deps.storage))
      .use(provider<Clock>((_) => deps.clock))
      .use(provider<Config>((_) => config));
}
