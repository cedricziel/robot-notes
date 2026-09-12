import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor_middleware.dart';
import 'package:server/src/app_deps_holder.dart' as app_deps_holder;
import 'package:server/src/auth_middleware.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/config_holder.dart' as config_holder;
import 'package:server/src/invite_store.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/consent_throttle.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:server/src/oidc/discovery.dart';
import 'package:server/src/oidc/jwks.dart';
import 'package:server/src/oidc/pending_login_store.dart';
import 'package:server/src/oidc/token_exchange.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/static_web_middleware.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/well_known_middleware.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';

/// Root route middleware applied to every request.
///
/// Order is bottom-up (last `.use` runs first):
///   1. `provider<Config>` and the long-lived dependency providers
///      ([Storage], [MetaIndex], [LinkIndex], [LockManager], [Broadcaster],
///      [PresenceTracker], [ClientStore], [CodeStore], [TokenStore],
///      [ConsentThrottle]) so handlers and downstream middleware can
///      `read<T>()` them.
///   2. [wellKnownMiddleware] answers the OAuth discovery documents
///      unauthenticated. It runs after the `Config` provider (it needs
///      the public base URL) but before [bearerAuth], since these
///      documents are how a client discovers the server before it has
///      any credential.
///   3. [bearerAuth] gates traffic on the configured API key (with
///      `GET /healthz` and the other unauthenticated paths — OAuth
///      discovery/registration/authorize/token, and `/mcp` — exempted
///      inside the middleware).
///   4. [actorIdentity] derives the display actor from `X-Actor` and
///      provides it via `context.read<Actor>()`. This runs after auth so
///      we never expose an actor to a handler that wouldn't otherwise
///      execute.
///   5. [staticWebMiddleware] runs outermost. When [Config.webDir] is
///      set, it serves the Flutter web bundle at the root and short-
///      circuits before the bearer-key check — the bundle is the same
///      static asset for everyone and never contains secrets. Requests
///      that match an API path (`/notes`, `/search`, `/ws`,
///      `/invites`, `/healthz`, `/mcp`, `/oauth`, `/.well-known`) pass
///      straight through to the rest of the chain.
///
/// The chain is built lazily on first request because the dart_frog
/// generated entrypoint calls `buildRootHandler()` before our
/// `entrypoint.run()` populates the Config/AppDeps holders.
Handler middleware(Handler handler) {
  Handler? chain;
  return (context) async {
    chain ??= () {
      final config = config_holder.config;
      final deps = app_deps_holder.appDeps;
      return handler
          .use(actorIdentity())
          .use(bearerAuth(configuredKey: config.apiKey))
          .use(wellKnownMiddleware())
          .use(provider<PresenceTracker>((_) => deps.presence))
          .use(provider<Broadcaster>((_) => deps.broadcaster))
          .use(provider<LockManager>((_) => deps.lockManager))
          .use(provider<SearchIndex>((_) => deps.searchIndex))
          .use(provider<InviteStore>((_) => deps.inviteStore))
          .use(provider<ClientStore>((_) => deps.clientStore))
          .use(provider<CodeStore>((_) => deps.codeStore))
          .use(provider<TokenStore>((_) => deps.tokenStore))
          .use(provider<ConsentThrottle>((_) => deps.consentThrottle))
          .use(provider<PendingLoginStore>((_) => deps.pendingLoginStore))
          .use(provider<OidcDiscoveryDocument?>((_) => deps.oidcDiscovery))
          .use(provider<JwksCache?>((_) => deps.oidcJwks))
          .use(provider<HttpPostForm>((_) => httpPostFormViaHttpClient))
          .use(provider<MetaIndex>((_) => deps.metaIndex))
          .use(provider<LinkIndex>((_) => deps.linkIndex))
          .use(provider<NoteWriteService>((_) => deps.noteWriteService))
          .use(provider<Storage>((_) => deps.storage))
          .use(provider<Clock>((_) => deps.clock))
          .use(provider<Config>((_) => config))
          .use(staticWebMiddleware(webDir: config.webDir));
    }();
    return chain!(context);
  };
}
