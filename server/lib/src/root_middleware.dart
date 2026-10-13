import 'package:dart_frog/dart_frog.dart';
import 'package:dart_otel_api/dart_otel_api.dart';
import 'package:server/src/actor_middleware.dart';
import 'package:server/src/agent_credentials.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/auth_middleware.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/evidence_store.dart';
import 'package:server/src/invite_store.dart';
import 'package:server/src/knowledge/runtime.dart';
import 'package:server/src/knowledge_middleware.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/knowledge_reads.dart';
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
import 'package:server/src/otel/http_trace_middleware.dart';
import 'package:server/src/proposals/proposal_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/static_web_middleware.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/upload_sessions.dart';
import 'package:server/src/vault_files.dart';
import 'package:server/src/vault_middleware.dart';
import 'package:server/src/vault_registry.dart';
import 'package:server/src/well_known_middleware.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';

/// Applies authentication, vault selection, dependency providers,
/// static serving, and tracing to [handler].
/// Dependencies remain scoped to this handler.
Handler applyRootMiddleware(
  Handler handler, {
  required AppDeps deps,
  required Config config,
  required TracerProvider tracerProvider,
  HttpPostForm httpPostForm = httpPostFormViaHttpClient,
}) {
  // Last .use runs first; providers must precede discovery and auth.
  return handler
      .use(vaultSelection(deps.vaults!))
      .use(knowledgeIdentity())
      .use(actorIdentity())
      .use(
        bearerAuth(
          configuredKey: config.apiKey,
          agentCredentials: deps.agentCredentials,
        ),
      )
      .use(wellKnownMiddleware())
      .use(provider<PresenceTracker>((_) => deps.presence))
      .use(provider<Broadcaster>((_) => deps.broadcaster))
      .use(provider<LockManager>((_) => deps.lockManager))
      .use(provider<SearchIndex>((_) => deps.searchIndex))
      .use(provider<AgentCredentialStore>((_) => deps.agentCredentials))
      .use(provider<InviteStore>((_) => deps.inviteStore))
      .use(provider<ClientStore>((_) => deps.clientStore))
      .use(provider<CodeStore>((_) => deps.codeStore))
      .use(provider<TokenStore>((_) => deps.tokenStore))
      .use(provider<ConsentThrottle>((_) => deps.consentThrottle))
      .use(provider<PendingLoginStore>((_) => deps.pendingLoginStore))
      .use(provider<OidcDiscoveryDocument?>((_) => deps.oidcDiscovery))
      .use(provider<JwksCache?>((_) => deps.oidcJwks))
      .use(provider<HttpPostForm>((_) => httpPostForm))
      .use(provider<MetaIndex>((_) => deps.metaIndex))
      .use(provider<LinkIndex>((_) => deps.linkIndex))
      .use(provider<KnowledgeReadService>((_) => deps.knowledgeReads))
      .use(provider<NoteAuthorizationService>((_) => deps.authorization))
      .use(provider<KnowledgePolicyStore>((_) => deps.authorization.store))
      .use(provider<NoteWriteService>((_) => deps.noteWriteService))
      .use(provider<DatabaseRegistry>((_) => deps.registry))
      .use(provider<KnowledgeRuntime>((_) => deps.knowledge))
      .use(provider<Storage>((_) => deps.storage))
      .use(provider<ProposalService>((_) => deps.proposals))
      .use(provider<EvidenceStore>((_) => deps.evidenceStore))
      .use(provider<FileStore>((_) => deps.fileStore))
      .use(provider<UploadSessionStore>((_) => deps.uploadSessions))
      .use(provider<VaultRegistry>((_) => deps.vaults!))
      .use(provider<Clock>((_) => deps.clock))
      .use(provider<Config>((_) => config))
      .use(staticWebMiddleware(webDir: config.webDir))
      .use(
        otelHttpTraceMiddleware(
          tracerProvider.getTracer(
            name: 'robot-notes-server',
          ),
        ),
      );
}
