import 'dart:async';
import 'dart:io';

import 'package:dart_otel_api/dart_otel_api.dart' hide Logger;
import 'package:logging/logging.dart';
import 'package:server/src/agent_credentials.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/embeddings/embedding_provider_factory.dart';
import 'package:server/src/evidence_store.dart';
import 'package:server/src/invite_store.dart';
import 'package:server/src/knowledge/extraction_model.dart';
import 'package:server/src/knowledge/runtime.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/knowledge_reads.dart';
import 'package:server/src/legacy_migration.dart';
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
import 'package:server/src/proposals/proposal_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/upload_sessions.dart';
import 'package:server/src/vault_files.dart';
import 'package:server/src/vault_registry.dart';
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
  ///
  /// A factory rather than a plain generative constructor: when [linkIndex]
  /// and/or [noteWriteService] are omitted, the default [LinkIndex] must be
  /// resolved exactly once and shared between [AppDeps.linkIndex] and the
  /// default [NoteWriteService]'s own copy — an initializer list can't
  /// express that without either referencing `this` (disallowed) or
  /// constructing two independent, silently-diverging `LinkIndex`es.
  factory AppDeps({
    required Storage storage,
    required MetaIndex metaIndex,
    required SearchIndex searchIndex,
    required InviteStore inviteStore,
    required ClientStore clientStore,
    required CodeStore codeStore,
    required TokenStore tokenStore,
    required ConsentThrottle consentThrottle,
    required LockManager lockManager,
    required Broadcaster broadcaster,
    required PresenceTracker presence,
    required Clock clock,
    AgentCredentialStore? agentCredentials,
    EvidenceStore? evidenceStore,
    NoteAuthorizationService? authorization,
    String vaultId = 'default',
    LinkIndex? linkIndex,
    NoteWriteService? noteWriteService,
    DatabaseRegistry? registry,
    OidcDiscoveryDocument? oidcDiscovery,
    JwksCache? oidcJwks,
    PendingLoginStore? pendingLoginStore,
    FileStore? fileStore,
    UploadSessionStore? uploadSessions,
    int maxUploadSizeBytes = Config.defaultMaxUploadSizeBytes,
    bool knowledgeEnabled = false,
    KnowledgeExtractionConfig? extractionConfig,
  }) {
    final resolvedLinkIndex = linkIndex ?? LinkIndex();
    final resolvedRegistry = registry ?? DatabaseRegistry();
    final resolvedAuthorization = authorization ??
        noteWriteService?.authorization ??
        NoteAuthorizationService(
          store: KnowledgePolicyStore.memory(),
          vaultId: vaultId,
          beforeMutation: storage.prepareHistory,
        );
    if (noteWriteService != null &&
        !identical(noteWriteService.authorization, resolvedAuthorization)) {
      throw ArgumentError(
        'Accepted reads and writes require the same authorization',
      );
    }
    final resolvedWriteService = noteWriteService ??
        NoteWriteService(
          storage: storage,
          authorization: resolvedAuthorization,
          metaIndex: metaIndex,
          searchIndex: searchIndex,
          broadcaster: broadcaster,
          linkIndex: resolvedLinkIndex,
          lockManager: lockManager,
          registry: resolvedRegistry,
        );
    storage.acceptedPolicyReplay =
        resolvedAuthorization.store.replayAcceptedNoteDesignation;
    resolvedAuthorization.beforePolicyPublish ??=
        resolvedWriteService.preparePolicyHistory;
    storage.requiresHistoryForNote = (note) => resolvedAuthorization.store
        .effective(KnowledgeTarget.note(note.id, note.path))
        .curated;
    final resolvedFileStore = (fileStore ??
        FileStore(contentDir: storage.contentDir))
      ..authorization = resolvedAuthorization;
    final resolvedUploads = uploadSessions ??
        UploadSessionStore(
          stagingDir: Directory('${storage.contentDir.parent.path}/uploads'),
          sweepInterval: null,
        );
    final authorizedUploads = resolvedUploads
      ..authorization = resolvedAuthorization;
    final deps = AppDeps._(
      knowledgeEnabled: knowledgeEnabled,
      extractionConfig: extractionConfig,
      evidenceStore: evidenceStore ??
          EvidenceStore(
            file: File('${storage.contentDir.parent.path}/evidence.db'),
            clock: clock,
            sweepInterval: const Duration(hours: 1),
          ),
      storage: storage,
      authorization: resolvedAuthorization,
      metaIndex: metaIndex,
      searchIndex: searchIndex,
      inviteStore: inviteStore,
      clientStore: clientStore,
      codeStore: codeStore,
      tokenStore: tokenStore,
      agentCredentials: agentCredentials ??
          AgentCredentialStore(
            dir: Directory('${inviteStore.inviteDir.parent.path}/credentials'),
            clock: clock,
          ),
      consentThrottle: consentThrottle,
      lockManager: lockManager,
      broadcaster: broadcaster,
      presence: presence,
      clock: clock,
      linkIndex: resolvedLinkIndex,
      noteWriteService: resolvedWriteService,
      registry: resolvedRegistry,
      oidcDiscovery: oidcDiscovery,
      oidcJwks: oidcJwks,
      pendingLoginStore: pendingLoginStore,
      fileStore: resolvedFileStore,
      // sweepInterval: null — this default is only reached by call sites
      // that don't care about upload sessions at all (most tests); a
      // background timer there would risk "pending timer" test-runner
      // warnings across the whole suite. Real production use goes
      // through bootstrap() below, which passes a real interval.
      uploadSessions: authorizedUploads,
      maxUploadSizeBytes: maxUploadSizeBytes,
    );
    deps.bindCredentialAuthority(deps);
    return deps;
  }

  AppDeps._({
    required this.evidenceStore,
    required this.knowledgeEnabled,
    required this.storage,
    required this.authorization,
    required this.metaIndex,
    required this.searchIndex,
    required this.inviteStore,
    required this.clientStore,
    required this.codeStore,
    required this.tokenStore,
    required this.agentCredentials,
    required this.consentThrottle,
    required this.lockManager,
    required this.broadcaster,
    required this.presence,
    required this.clock,
    required this.linkIndex,
    required this.noteWriteService,
    required this.registry,
    required this.fileStore,
    required this.uploadSessions,
    required this.maxUploadSizeBytes,
    this.extractionConfig,
    this.oidcDiscovery,
    this.oidcJwks,
    PendingLoginStore? pendingLoginStore,
  }) : pendingLoginStore = pendingLoginStore ?? PendingLoginStore() {
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
  /// - [tracer] forwarded to [NoteWriteService] so note writes get a span;
  ///   optional (defaults to a no-op) so tests can call this without an
  ///   otel pipeline
  static Future<AppDeps> bootstrap(
    Config config, {
    Clock clock = const Clock(),
    Logger? logger,
    Tracer? tracer,
    HttpGet oidcHttpGet = httpGetViaHttpClient,
    bool initializeVaults = true,
    String vaultId = 'default',
  }) async {
    final log = logger ?? Logger('app_deps');
    final contentDir = Directory('${config.dataDir}/content');
    final migrated = await migrateLegacyLayout(
      contentDir: contentDir,
      logger: Logger('legacy_migration'),
    );
    if (migrated > 0) {
      log.info('Migrated $migrated legacy note file(s) to vault layout');
    }
    final storage = Storage(contentDir: contentDir, clock: clock);
    final policies = KnowledgePolicyStore(
      file: File('${config.dataDir}/knowledge-policy.json'),
    );
    await policies.load();
    storage
      ..acceptedPolicyReplay = policies.replayAcceptedNoteDesignation
      ..requiresHistoryForNote = (note) =>
          policies.effective(KnowledgeTarget.note(note.id, note.path)).curated;
    final authorization = NoteAuthorizationService(
      store: policies,
      vaultId: vaultId,
      beforeMutation: storage.prepareHistory,
    );
    final fileStore = FileStore(contentDir: contentDir);
    final uploadSessions = UploadSessionStore(
      stagingDir: Directory('${config.dataDir}/uploads'),
      clock: clock,
    );
    final metaIndex = MetaIndex();
    final loaded = await metaIndex.scan(storage);
    log.info('Bootstrapped MetaIndex with $loaded note(s)');
    final linkIndex = LinkIndex();
    final linksLoaded = await linkIndex.scan(
      metaIndex: metaIndex,
      storage: storage,
    );
    log.info('Bootstrapped LinkIndex with $linksLoaded note(s)');
    final lockManager = LockManager(
      clock: clock,
      ttl: Duration(seconds: config.lockTtlSeconds),
    );
    final embeddingProvider = embeddingProviderFromConfig(config);
    final searchIndex = await SearchIndex.open(
      dbFile: File('${config.dataDir}/search.db'),
      storage: storage,
      logger: Logger('search_index'),
      tracer: tracer,
      embeddingProvider: embeddingProvider,
    );
    final registry = DatabaseRegistry(logger: Logger('databases.registry'))
      ..rebuild([
        for (final row in searchIndex.definitionsSource())
          if (metaIndex.get(row.id) != null)
            (metaIndex.get(row.id)!, row.extra),
      ]);
    log.info('Bootstrapped DatabaseRegistry with ${registry.all.length} '
        'definition(s)');

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

    final broadcaster = Broadcaster();
    final noteWriteService = NoteWriteService(
      authorization: authorization,
      storage: storage,
      metaIndex: metaIndex,
      searchIndex: searchIndex,
      broadcaster: broadcaster,
      linkIndex: linkIndex,
      lockManager: lockManager,
      tracer: tracer,
      embeddingProvider: embeddingProvider,
      registry: registry,
    );

    final deps = AppDeps(
      authorization: authorization,
      vaultId: vaultId,
      storage: storage,
      metaIndex: metaIndex,
      searchIndex: searchIndex,
      inviteStore: inviteStore,
      clientStore: clientStore,
      codeStore: codeStore,
      tokenStore: tokenStore,
      consentThrottle: consentThrottle,
      lockManager: lockManager,
      broadcaster: broadcaster,
      presence: PresenceTracker(),
      clock: clock,
      linkIndex: linkIndex,
      noteWriteService: noteWriteService,
      registry: registry,
      oidcDiscovery: oidcDiscovery,
      oidcJwks: oidcJwks,
      pendingLoginStore: PendingLoginStore(clock: clock),
      fileStore: fileStore,
      uploadSessions: uploadSessions,
      maxUploadSizeBytes: config.maxUploadSizeBytes,
      knowledgeEnabled: config.knowledgeEnabled,
      extractionConfig: config.extraction,
    );
    if (initializeVaults) {
      deps.vaults = VaultRegistry(root: deps, config: config);
      await deps.vaults!.load();
      if (deps.knowledgeEnabled) deps.knowledge.start();
    }
    return deps;
  }

  /// Explicit activation of the new services; existing deployments default off.
  final bool knowledgeEnabled;

  /// Optional independent extraction provider settings.
  final KnowledgeExtractionConfig? extractionConfig;
  KnowledgeRuntime? _knowledge;

  /// Lazily binds selected-vault knowledge services without altering disabled
  /// flows.
  KnowledgeRuntime get knowledge => _knowledge ??= KnowledgeRuntime(
        enabled: knowledgeEnabled,
        storage: storage,
        authorization: authorization,
        writes: noteWriteService,
        extractionConfig: extractionConfig,
        clock: clock,
        resolveOrigin: (id) async {
          final principal = id == 'operator'
              ? const KnowledgePrincipal.operator()
              : id.startsWith('agent:')
                  ? KnowledgePrincipal.agent(
                      credentialId: id.substring(6),
                      scopes: {},
                    )
                  : id.startsWith('oauth:')
                      ? KnowledgePrincipal.oauth(
                          grantId: id.substring(6),
                          scopes: {},
                        )
                      : const KnowledgePrincipal.unidentified();
          return uploadSessions.revalidatePrincipal?.call(principal);
        },
      );

  /// Server-wide vault catalog; absent for single-vault test bundles.
  VaultRegistry? vaults;

  /// Canonical filesystem-backed note store.
  final Storage storage;

  /// Durable conversation evidence, excluded from note indexes.
  final EvidenceStore evidenceStore;

  /// Trusted capabilities and policy for this vault.
  /// Revalidates upload issuers against the root authentication ledger.
  void bindCredentialAuthority(AppDeps root) {
    uploadSessions.revalidatePrincipal = (principal) async {
      if (principal.kind == KnowledgePrincipalKind.operator) return principal;
      if (principal.kind == KnowledgePrincipalKind.agent) {
        final matching = (await root.agentCredentials.list()).where(
          (record) =>
              record.revokedAt == null && 'agent:${record.id}' == principal.id,
        );
        if (matching.isEmpty) return null;
        final record = matching.single;
        return KnowledgePrincipal.agent(
          credentialId: record.id,
          scopes: record.scopes,
          vaultIds: record.vaultIds,
        );
      }
      if (principal.kind == KnowledgePrincipalKind.oauth) {
        final matching = (await root.tokenStore.liveGrants())
            .where((record) => 'oauth:${record.grantId}' == principal.id);
        if (matching.isEmpty) return null;
        final record = matching.single;
        final current = KnowledgePrincipal.oauth(
          grantId: record.grantId,
          scopes: record.scopes,
          vaultIds: record.vaultIds,
        );
        return principal.isAgentOrigin ? current.withAgentOrigin() : current;
      }
      return null;
    };
  }

  /// Builds review handlers over this vault's authoritative services.
  ProposalService get proposals => ProposalService(
        storage: storage,
        authorization: authorization,
        onAccepted: noteWriteService.indexAcceptedProposal,
        validateDraft: noteWriteService.validateProposalDraft,
        clock: clock,
        archiveReader: (digest) async =>
            evidenceStore.read(digest)?.cast<String, dynamic>(),
      );

  /// Selected-vault read filters share the accepted-write authorization.
  KnowledgeReadService get knowledgeReads => KnowledgeReadService(
        authorization: authorization,
        metaIndex: metaIndex,
        writes: noteWriteService,
      );

  /// Shared policy enforcement for the selected vault.
  final NoteAuthorizationService authorization;

  /// Write path for uploaded (non-note) files, rooted at the same
  /// `contentDir` as [storage].
  final FileStore fileStore;

  /// Maximum accepted upload size, in bytes — see `Config.maxUploadSizeBytes`.
  /// Captured here (rather than threading `Config` itself through) so MCP
  /// tools, which are built once from [AppDeps] with no per-call request
  /// context, can enforce the same limit `POST /notes/files` does.
  final int maxUploadSizeBytes;

  /// Registry of in-flight two-phase (`request_upload`/`finalize_upload`)
  /// upload slots, staging bytes outside [Storage.contentDir].
  final UploadSessionStore uploadSessions;

  /// In-memory listing index, derived from [storage].
  final MetaIndex metaIndex;

  /// Outgoing-link index, derived from [storage]. Backs rename propagation
  /// and the backlinks/links endpoints.
  final LinkIndex linkIndex;

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

  /// Server-wide scoped agent identities and revocations.
  final AgentCredentialStore agentCredentials;

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

  /// In-memory database-definition registry — see the `add-databases`
  /// design's "Definition notes are parsed into an in-memory
  /// `DatabaseRegistry`" decision. Kept current on every write by
  /// [noteWriteService] (constructed sharing this same instance); rebuilt
  /// from [searchIndex]'s `definitionsSource()` scan at [bootstrap].
  final DatabaseRegistry registry;

  StreamSubscription<LockEvent>? _lockSub;

  /// Releases long-lived resources. Tests use this between scenarios; the
  /// production server keeps a single [AppDeps] for its full lifetime.
  Future<void> close() async {
    await vaults?.close();
    await _knowledge?.close();
    await _lockSub?.cancel();
    _lockSub = null;
    await broadcaster.close();
    await lockManager.close();
    searchIndex.close();
    evidenceStore.close();
    uploadSessions.dispose();
    await agentCredentials.dispose();
    await authorization.store.dispose();
  }
}
