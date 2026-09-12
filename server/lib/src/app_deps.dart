import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/invite_store.dart';
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
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';
import 'package:shared/shared.dart';

/// Long-lived dependencies shared across the whole server process.
///
/// Each request gets the same [Storage], [MetaIndex], [LockManager],
/// [Broadcaster], and [PresenceTracker] instances threaded through the
/// request context. Constructed once at boot from the resolved [Config] and
/// held by `app_deps_holder.dart`.
class AppDeps {
  /// Constructs a deps bundle wrapping the supplied collaborators directly.
  /// Tests use this to inject fakes; production callers should prefer
  /// [AppDeps.bootstrap].
  AppDeps({
    required this.storage,
    required this.metaIndex,
    required this.searchIndex,
    required this.inviteStore,
    required this.clientStore,
    required this.codeStore,
    required this.tokenStore,
    required this.consentThrottle,
    required this.lockManager,
    required this.broadcaster,
    required this.presence,
    required this.clock,
    this.oidcDiscovery,
    this.oidcJwks,
    PendingLoginStore? pendingLoginStore,
    NoteWriteService? noteWriteService,
  })  : pendingLoginStore = pendingLoginStore ?? PendingLoginStore(),
        noteWriteService = noteWriteService ??
            NoteWriteService(
              storage: storage,
              metaIndex: metaIndex,
              searchIndex: searchIndex,
              broadcaster: broadcaster,
            ) {
    _lockSub = lockManager.transitions.listen(broadcaster.emitLock);
  }

  /// Builds a deps bundle from the resolved [config], wiring up:
  /// - [Storage] rooted at `<dataDir>/content`
  /// - [MetaIndex] populated by scanning [Storage]
  /// - [LockManager] with TTL from `config.lockTtlSeconds`
  /// - [Broadcaster] subscribed to lock-manager transitions
  /// - [PresenceTracker] for per-note viewer rosters
  /// - [ClientStore], [CodeStore], [TokenStore] rooted at
  ///   `<dataDir>/oauth/{clients,codes,tokens}`, with expired codes and
  ///   tokens purged before the bundle is returned
  /// - [ConsentThrottle], sharing [clock] with everything else
  /// - [oidcDiscovery], fetched from `config.oidc.issuer` when OIDC login
  ///   is configured; a failure here fails bootstrap, since a
  ///   misconfigured issuer should not silently disable OIDC login
  static Future<AppDeps> bootstrap(
    Config config, {
    Clock clock = const Clock(),
    Logger? logger,
    HttpGet oidcHttpGet = httpGetViaHttpClient,
  }) async {
    final log = logger ?? Logger('app_deps');
    final contentDir = Directory('${config.dataDir}/content');
    final storage = Storage(contentDir: contentDir, clock: clock);
    final metaIndex = MetaIndex();
    final loaded = await metaIndex.scan(storage);
    log.info('Bootstrapped MetaIndex with $loaded note(s)');
    final lockManager = LockManager(
      clock: clock,
      ttl: Duration(seconds: config.lockTtlSeconds),
    );
    final searchIndex = await SearchIndex.open(
      dbFile: File('${config.dataDir}/search.db'),
      storage: storage,
      logger: Logger('search_index'),
    );
    final inviteStore = InviteStore(
      inviteDir: Directory('${config.dataDir}/invites'),
      clock: clock,
    );
    final clientStore = ClientStore(
      dir: Directory('${config.dataDir}/oauth/clients'),
      clock: clock,
    );
    final codeStore = CodeStore(
      dir: Directory('${config.dataDir}/oauth/codes'),
      clock: clock,
    );
    final tokenStore = TokenStore(
      dir: Directory('${config.dataDir}/oauth/tokens'),
      clock: clock,
      onGrantRevoked: codeStore.revokeGrant,
    );
    final consentThrottle = ConsentThrottle(clock: clock);
    final purgedCodes = await codeStore.purgeExpired();
    final purgedTokens = await tokenStore.purgeExpired();
    log.info(
      'Purged $purgedCodes expired OAuth code(s) and '
      '$purgedTokens expired OAuth token(s)',
    );

    OidcDiscoveryDocument? oidcDiscovery;
    JwksCache? oidcJwks;
    final oidcConfig = config.oidc;
    if (oidcConfig != null) {
      oidcDiscovery = await fetchOidcDiscovery(
        oidcConfig.issuer,
        httpGet: oidcHttpGet,
      );
      oidcJwks = JwksCache(
        jwksUri: oidcDiscovery.jwksUri,
        httpGet: oidcHttpGet,
      );
      log.info('Resolved OIDC discovery document from ${oidcConfig.issuer}');
    }

    return AppDeps(
      storage: storage,
      metaIndex: metaIndex,
      searchIndex: searchIndex,
      inviteStore: inviteStore,
      clientStore: clientStore,
      codeStore: codeStore,
      tokenStore: tokenStore,
      consentThrottle: consentThrottle,
      lockManager: lockManager,
      broadcaster: Broadcaster(),
      presence: PresenceTracker(),
      clock: clock,
      oidcDiscovery: oidcDiscovery,
      oidcJwks: oidcJwks,
      pendingLoginStore: PendingLoginStore(clock: clock),
    );
  }

  /// Canonical filesystem-backed note store.
  final Storage storage;

  /// In-memory listing index, derived from [storage].
  final MetaIndex metaIndex;

  /// FTS5-backed full-text search index, derived from [storage].
  final SearchIndex searchIndex;

  /// Filesystem-backed agent-onboarding invite store.
  final InviteStore inviteStore;

  /// Filesystem-backed Dynamic-Client-Registration store.
  final ClientStore clientStore;

  /// Filesystem-backed PKCE authorization-code store.
  final CodeStore codeStore;

  /// Filesystem-backed OAuth access/refresh token store.
  final TokenStore tokenStore;

  /// Process-local rate limit on failed `/oauth/authorize` consent
  /// submissions.
  final ConsentThrottle consentThrottle;

  /// Soft editor lock manager (process-local).
  final LockManager lockManager;

  /// Routing layer that fans LockEvents, ChangedEvents, and PresenceEvents
  /// out to subscribed WebSocket connections.
  final Broadcaster broadcaster;

  /// Per-note viewer roster used by the WS layer.
  final PresenceTracker presence;

  /// Clock injected into every time-stamping component.
  final Clock clock;

  /// The configured OIDC issuer's resolved discovery document, or `null`
  /// when OIDC login is not configured (`config.oidc == null`).
  final OidcDiscoveryDocument? oidcDiscovery;

  /// A cache of the configured OIDC issuer's JWKS document, or `null`
  /// when OIDC login is not configured. Shared across every ID-token
  /// verification so the JWKS document is not refetched per callback.
  final JwksCache? oidcJwks;

  /// Process-local store of in-flight OIDC logins, keyed by `state`.
  final PendingLoginStore pendingLoginStore;

  /// Orchestrates filesystem + search + meta + broadcast on every note
  /// write, so the routes don't have to remember the dependency order.
  final NoteWriteService noteWriteService;

  StreamSubscription<LockEvent>? _lockSub;

  /// Releases long-lived resources. Tests use this between scenarios; the
  /// production server keeps a single [AppDeps] for its full lifetime.
  Future<void> close() async {
    await _lockSub?.cancel();
    _lockSub = null;
    await broadcaster.close();
    await lockManager.close();
    searchIndex.close();
  }
}
