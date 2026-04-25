// The Router/Pipeline integration with handler tear-offs trips two
// competing strict-mode lints in this file (closures vs. tear-offs). The
// shape mirrors what dart_frog's own code generator emits, so we silence
// both rather than fighting the framework.
// ignore_for_file: implicit_call_tearoffs, unnecessary_lambdas

import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor_middleware.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/auth_middleware.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/invite_store.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';

import '../../routes/healthz.dart' as healthz_route;
import '../../routes/index.dart' as root_index;
import '../../routes/invites/[token].dart' as invites_token_route;
import '../../routes/invites/[token]/onboarding.txt.dart'
    as invites_token_onboarding_route;
import '../../routes/invites/index.dart' as invites_index_route;
import '../../routes/notes/[id].dart' as notes_id_route;
import '../../routes/notes/[id]/lock.dart' as notes_id_lock_route;
import '../../routes/notes/index.dart' as notes_index_route;
import '../../routes/search.dart' as search_route;
import '../../routes/ws.dart' as ws_route;

/// Spins up an HTTP server bound to a loopback ephemeral port that mirrors
/// the production routing tree. Tests inject [deps] and [config] directly
/// instead of going through the global holders, so multiple integration
/// tests can run in the same process without polluting each other.
///
/// The handler tree is hand-wired here to match what `dart_frog build`
/// would generate from `routes/`. Keep it in sync if you add a new route.
Future<HttpServer> startTestServer({
  required AppDeps deps,
  required Config config,
}) {
  final pipeline = const Pipeline()
      .addMiddleware(actorIdentity())
      .addMiddleware(bearerAuth(configuredKey: config.apiKey))
      .addMiddleware(provider<PresenceTracker>((_) => deps.presence))
      .addMiddleware(provider<Broadcaster>((_) => deps.broadcaster))
      .addMiddleware(provider<LockManager>((_) => deps.lockManager))
      .addMiddleware(provider<SearchIndex>((_) => deps.searchIndex))
      .addMiddleware(provider<InviteStore>((_) => deps.inviteStore))
      .addMiddleware(provider<MetaIndex>((_) => deps.metaIndex))
      .addMiddleware(provider<NoteWriteService>((_) => deps.noteWriteService))
      .addMiddleware(provider<Storage>((_) => deps.storage))
      .addMiddleware(provider<Clock>((_) => deps.clock))
      .addMiddleware(provider<Config>((_) => config));

  final root = Router()
    ..mount('/notes/<id>/lock', _lockMount)
    ..mount('/notes/<id>', _notesIdMount)
    ..mount('/notes', _notesIndexMount)
    ..mount('/invites/<token>/onboarding.txt', _onboardingMount)
    ..mount('/invites/<token>', _invitesTokenMount)
    ..mount('/invites', _invitesIndexMount)
    ..all('/healthz', healthz_route.onRequest)
    ..all('/search', search_route.onRequest)
    ..all('/ws', ws_route.onRequest)
    ..all('/', root_index.onRequest);

  final handler = pipeline.addHandler(root);
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
  TestApp._(this.server, this.deps, this.config, this.tmpDir);

  final HttpServer server;
  final AppDeps deps;
  final Config config;
  final Directory tmpDir;

  /// Spins up a test app rooted at a fresh temp directory.
  static Future<TestApp> start({
    String apiKey = 'integration-key',
    int lockTtlSeconds = 60,
    Clock? clock,
  }) async {
    final tmpDir =
        Directory.systemTemp.createTempSync('robot-notes-integration-');
    final config = Config(
      apiKey: apiKey,
      dataDir: tmpDir.path,
      port: 0,
      lockTtlSeconds: lockTtlSeconds,
    );
    final deps = await AppDeps.bootstrap(
      config,
      clock: clock ?? const Clock(),
    );
    final server = await startTestServer(deps: deps, config: config);
    return TestApp._(server, deps, config, tmpDir);
  }

  String get baseUrl => 'http://${server.address.host}:${server.port}';

  String get wsUrl => 'ws://${server.address.host}:${server.port}/ws';

  Map<String, String> headers({String actor = 'tester'}) => {
        'Authorization': 'Bearer ${config.apiKey}',
        'X-Actor': actor,
        'Content-Type': 'application/json',
      };

  Future<void> close() async {
    await server.close(force: true);
    await deps.close();
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  }
}
