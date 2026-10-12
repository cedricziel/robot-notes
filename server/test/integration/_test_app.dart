// The Router/Pipeline integration with handler tear-offs trips two
// competing strict-mode lints in this file (closures vs. tear-offs). The
// shape mirrors what dart_frog's own code generator emits, so we silence
// both rather than fighting the framework.
// ignore_for_file: implicit_call_tearoffs, unnecessary_lambdas

import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:dart_otel_api/dart_otel_api.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/mcp/mcp_chain.dart';
import 'package:server/src/oidc/discovery.dart';
import 'package:server/src/oidc/token_exchange.dart';
import 'package:server/src/otel/otel_tracer_holder.dart' as otel_tracer_holder;
import 'package:server/src/root_middleware.dart';
import 'package:server/src/vault_registry.dart';

import '../../routes/credentials/[id].dart' as credential_route;
import '../../routes/credentials/index.dart' as credentials_route;
import '../../routes/databases/[id]/index.dart' as databases_id_route;
import '../../routes/databases/[id]/query.dart' as databases_id_query_route;
import '../../routes/databases/[id]/rows.dart' as databases_id_rows_route;
import '../../routes/databases/index.dart' as databases_index_route;
import '../../routes/evidence/[id].dart' as evidence_route;
import '../../routes/healthz.dart' as healthz_route;
import '../../routes/index.dart' as root_index;
import '../../routes/invites/[token]/index.dart' as invites_token_route;
import '../../routes/invites/[token]/onboarding.txt.dart'
    as invites_token_onboarding_route;
import '../../routes/invites/index.dart' as invites_index_route;
import '../../routes/knowledge/policies.dart' as knowledge_policies_route;
import '../../routes/knowledge/principals.dart' as knowledge_principals_route;
import '../../routes/mcp/index.dart' as mcp_route;
import '../../routes/notes/[id]/append.dart' as notes_append_route;
import '../../routes/notes/[id]/backlinks.dart' as notes_backlinks_route;
import '../../routes/notes/[id]/blocks.dart' as notes_blocks_route;
import '../../routes/notes/[id]/comments.dart' as note_comments_route;
import '../../routes/notes/[id]/history.dart' as notes_history_route;
import '../../routes/notes/[id]/index.dart' as notes_id_route;
import '../../routes/notes/[id]/links.dart' as notes_links_route;
import '../../routes/notes/[id]/lock.dart' as notes_id_lock_route;
import '../../routes/notes/[id]/permissions.dart' as note_permissions_route;
import '../../routes/notes/[id]/properties.dart' as notes_id_properties_route;
import '../../routes/notes/[id]/proposals/[proposalId]/comments.dart'
    as proposal_comments_route;
import '../../routes/notes/[id]/proposals/[proposalId]/decisions.dart'
    as proposal_decisions_route;
import '../../routes/notes/[id]/proposals/[proposalId]/index.dart'
    as proposal_item_route;
import '../../routes/notes/[id]/proposals/index.dart' as proposals_note_route;
import '../../routes/notes/file-uploads/[token].dart' as upload_route;
import '../../routes/notes/files/[...path].dart' as file_route;
import '../../routes/notes/files/index.dart' as files_route;
import '../../routes/notes/index.dart' as notes_index_route;
import '../../routes/notes/permissions.dart' as prospective_permissions_route;
import '../../routes/notes/proposals.dart' as proposals_index_route;
import '../../routes/notes/tree.dart' as notes_tree_route;
import '../../routes/oauth/authorize.dart' as oauth_authorize_route;
import '../../routes/oauth/oidc/callback.dart' as oauth_oidc_callback_route;
import '../../routes/oauth/oidc/login.dart' as oauth_oidc_login_route;
import '../../routes/oauth/register.dart' as oauth_register_route;
import '../../routes/oauth/revoke.dart' as oauth_revoke_route;
import '../../routes/oauth/token.dart' as oauth_token_route;
import '../../routes/otel-config.dart' as otel_config_route;
import '../../routes/search.dart' as search_route;
import '../../routes/tags.dart' as tags_route;
import '../../routes/vaults/[id]/index.dart' as vault_id_route;
import '../../routes/vaults/index.dart' as vaults_route;
import '../../routes/ws.dart' as ws_route;

// `ws_route.onRequest` reads the tracer straight from the process-wide
// holder (mirroring production, which populates it in server/main.dart
// before serve()). This harness has no equivalent bootstrap step, so it
// must set one explicitly — with the SAME instance on every call, since
// `setOtelTracerProvider` throws if called twice with different ones and
// each test file's tests share an isolate.
const _testTracerProvider = NoopTracerProvider();

/// Spins up an HTTP server bound to a loopback ephemeral port that mirrors
/// production middleware with isolated routing. Tests inject [deps] and
/// [config] directly
/// instead of going through the global holders, so multiple integration
/// tests can run in the same process without polluting each other.
///
/// The handler tree is hand-wired here to match what `dart_frog build`
/// would generate from `routes/`. Keep it in sync if you add a new route.
Future<HttpServer> startTestServer({
  required AppDeps deps,
  required Config config,
  HttpPostForm httpPostForm = httpPostFormViaHttpClient,
}) async {
  deps.vaults ??= VaultRegistry(root: deps, config: config);
  await deps.vaults!.load();
  otel_tracer_holder.setOtelTracerProvider(_testTracerProvider);

  // `/mcp` gets its own middleware nesting via the shared [mcpChain],
  // mirroring routes/mcp/_middleware.dart: the McpHandler provider and
  // mcpAuth both scoped to this one route rather than the shared pipeline
  // above, since mcpAuth's credential rules (static key OR OAuth access
  // token, no exemptions) would otherwise apply to every other route too.
  // Unlike the production middleware, [deps] is captured directly instead
  // of going through `app_deps_holder`, so parallel test servers do not
  // share global state.
  final mcpHandler = mcpChain(
    (RequestContext c) => mcp_route.onRequest(c),
    deps: deps,
  );

  final root = Router()
    ..all('/knowledge/policies', knowledge_policies_route.onRequest)
    ..all('/knowledge/principals', knowledge_principals_route.onRequest)
    ..all('/notes/permissions', prospective_permissions_route.onRequest)
    ..all('/notes/<id>/permissions', note_permissions_route.onRequest)
    ..all('/credentials', credentials_route.onRequest)
    ..all('/credentials/<id>', credential_route.onRequest)
    ..all('/evidence/<id>', evidence_route.onRequest)
    ..all('/notes/file-uploads/<token>', upload_route.onRequest)
    ..all('/notes/tree', notes_tree_route.onRequest)
    ..all('/notes/files', files_route.onRequest)
    ..all('/notes/files/<path|.*>', file_route.onRequest)
    ..all('/notes/proposals', proposals_index_route.onRequest)
    ..all('/notes/<id>/proposals', proposals_note_route.onRequest)
    ..all('/notes/<id>/proposals/<proposalId>', proposal_item_route.onRequest)
    ..all(
      '/notes/<id>/proposals/<proposalId>/comments',
      proposal_comments_route.onRequest,
    )
    ..all(
      '/notes/<id>/proposals/<proposalId>/decisions',
      proposal_decisions_route.onRequest,
    )
    ..all('/notes/<id>/comments', note_comments_route.onRequest)
    ..all('/notes/<id>/blocks', notes_blocks_route.onRequest)
    ..all('/notes/<id>/history', notes_history_route.onRequest)
    ..all('/notes/<id>/append', notes_append_route.onRequest)
    ..all('/notes/<id>/backlinks', notes_backlinks_route.onRequest)
    ..all('/notes/<id>/links', notes_links_route.onRequest)
    ..mount('/notes/<id>/lock', _lockMount)
    ..mount('/notes/<id>/properties', _notesIdPropertiesMount)
    ..mount('/notes/<id>', _notesIdMount)
    ..mount('/notes', _notesIndexMount)
    ..mount('/databases/<id>/query', _databasesIdQueryMount)
    ..mount('/databases/<id>/rows', _databasesIdRowsMount)
    ..mount('/databases/<id>', _databasesIdMount)
    ..mount('/databases', _databasesIndexMount)
    ..mount('/invites/<token>/onboarding.txt', _onboardingMount)
    ..mount('/invites/<token>', _invitesTokenMount)
    ..mount('/invites', _invitesIndexMount)
    ..all('/vaults', vaults_route.onRequest)
    ..all('/vaults/<id>', vault_id_route.onRequest)
    ..all('/healthz', healthz_route.onRequest)
    ..all('/search', search_route.onRequest)
    ..all('/tags', tags_route.onRequest)
    ..all('/otel-config', otel_config_route.onRequest)
    ..all('/ws', ws_route.onRequest)
    ..all('/mcp', mcpHandler)
    ..all('/oauth/register', oauth_register_route.onRequest)
    ..all('/oauth/authorize', oauth_authorize_route.onRequest)
    ..all('/oauth/oidc/login', oauth_oidc_login_route.onRequest)
    ..all('/oauth/oidc/callback', oauth_oidc_callback_route.onRequest)
    ..all('/oauth/token', oauth_token_route.onRequest)
    ..all('/oauth/revoke', oauth_revoke_route.onRequest)
    ..all('/', root_index.onRequest);

  final handler = applyRootMiddleware(
    root.call,
    deps: deps,
    config: config,
    tracerProvider: _testTracerProvider,
    httpPostForm: httpPostForm,
  );
  return serve(handler, InternetAddress.loopbackIPv4, 0);
}

FutureOr<Response> _notesIndexMount(RequestContext context) {
  return notes_index_route.onRequest(context);
}

FutureOr<Response> _notesIdMount(RequestContext context, String id) {
  return notes_id_route.onRequest(context, id);
}

FutureOr<Response> _lockMount(RequestContext context, String id) {
  return notes_id_lock_route.onRequest(context, id);
}

FutureOr<Response> _notesIdPropertiesMount(RequestContext context, String id) {
  return notes_id_properties_route.onRequest(context, id);
}

FutureOr<Response> _databasesIndexMount(RequestContext context) {
  return databases_index_route.onRequest(context);
}

FutureOr<Response> _databasesIdMount(RequestContext context, String id) {
  return databases_id_route.onRequest(context, id);
}

FutureOr<Response> _databasesIdQueryMount(RequestContext context, String id) {
  return databases_id_query_route.onRequest(context, id);
}

FutureOr<Response> _databasesIdRowsMount(RequestContext context, String id) {
  return databases_id_rows_route.onRequest(context, id);
}

FutureOr<Response> _invitesIndexMount(RequestContext context) {
  return invites_index_route.onRequest(context);
}

FutureOr<Response> _invitesTokenMount(RequestContext context, String token) {
  return invites_token_route.onRequest(context, token);
}

FutureOr<Response> _onboardingMount(RequestContext context, String token) {
  return invites_token_onboarding_route.onRequest(context, token);
}

/// Convenience around an [HttpServer] running [startTestServer]. Holds the
/// server, the [AppDeps] that back it, and a base URL for HTTP clients.
class TestApp {
  /// Wraps an [HttpServer]/[AppDeps]/[Config] already built by hand (e.g.
  /// a test that needs to reopen the same [dataDir] after closing a first
  /// [TestApp], to exercise a restart) into the same convenience surface
  /// [start] returns.
  TestApp.wrap(
    HttpServer server,
    AppDeps deps,
    Config config,
    Directory dataDir,
  ) : this._(server, deps, config, dataDir);

  TestApp._(this.server, this.deps, this.config, this.tmpDir);

  final HttpServer server;
  final AppDeps deps;
  final Config config;
  final Directory tmpDir;

  /// Spins up a test app rooted at a fresh temp directory. [oidcConfig],
  /// [oidcHttpGet], and [httpPostForm] let a test wire in a stub OIDC
  /// provider instead of making real network calls.
  static Future<TestApp> start({
    String apiKey = 'integration-key',
    int lockTtlSeconds = 60,
    Clock? clock,
    String? webDir,
    OidcConfig? oidcConfig,
    HttpGet oidcHttpGet = httpGetViaHttpClient,
    HttpPostForm httpPostForm = httpPostFormViaHttpClient,
  }) async {
    final tmpDir =
        Directory.systemTemp.createTempSync('robot-notes-integration-');
    final config = Config(
      apiKey: apiKey,
      dataDir: tmpDir.path,
      port: 0,
      lockTtlSeconds: lockTtlSeconds,
      oidc: oidcConfig,
      webDir: webDir,
    );
    final deps = await AppDeps.bootstrap(
      config,
      clock: clock ?? const Clock(),
      oidcHttpGet: oidcHttpGet,
    );
    final server = await startTestServer(
      deps: deps,
      config: config,
      httpPostForm: httpPostForm,
    );
    return TestApp._(server, deps, config, tmpDir);
  }

  String get baseUrl => 'http://${server.address.host}:${server.port}';

  String get wsUrl => 'ws://${server.address.host}:${server.port}/ws';

  Map<String, String> headers({String actor = 'tester'}) => {
        'Authorization': 'Bearer ${config.apiKey}',
        'X-Actor': actor,
        'Content-Type': 'application/json',
      };

  /// Shuts the server and [deps] down. [deleteDir] defaults to `true`
  /// (removing [tmpDir]); a test that reopens the same [tmpDir] — to
  /// exercise a restart against the same on-disk vault — passes `false`
  /// and deletes it itself once done.
  Future<void> close({bool deleteDir = true}) async {
    await server.close(force: true);
    await deps.close();
    if (deleteDir && tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  }
}
