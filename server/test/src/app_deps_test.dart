import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/app_deps_holder.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/embeddings/ollama_embedding_provider.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oidc/discovery.dart';
import 'package:shared/shared.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-app-deps-test-');
}

Config _config(Directory tmp) => Config(
      apiKey: 'rn_test',
      dataDir: tmp.path,
      port: 8080,
      lockTtlSeconds: 60,
    );

Config _embeddingConfig(Directory tmp) => Config(
      apiKey: 'rn_test',
      dataDir: tmp.path,
      port: 8080,
      lockTtlSeconds: 60,
      embeddingProvider: 'ollama',
    );

void main() {
  group('AppDeps.bootstrap', () {
    late Directory tmp;

    setUp(() {
      tmp = _tempDir();
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('builds storage rooted at <dataDir>/content', () async {
      final deps = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      expect(deps.storage.contentDir.path, '${tmp.path}/content');
    });

    test('scans existing files into the meta index on bootstrap', () async {
      final deps = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      // Empty data dir → empty index.
      expect(deps.metaIndex.length, 0);

      // Seed two notes through the storage and rebuild deps to confirm the
      // index picks them up on the next bootstrap call.
      await deps.storage.create(title: 'a', content: '');
      await deps.storage.create(title: 'b', content: '');

      final reloaded = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      expect(reloaded.metaIndex.length, 2);
    });

    test('uses lockTtlSeconds from the config for the lock manager', () async {
      final cfg = Config(
        apiKey: 'rn_test',
        dataDir: tmp.path,
        port: 8080,
        lockTtlSeconds: 30,
      );
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 0, 5),
      ]);
      final deps = await AppDeps.bootstrap(cfg, clock: clock);
      addTearDown(deps.close);
      final lock = await deps.lockManager.acquire(noteId: 'n1', actor: 'alice');
      expect(lock.expiresAt, DateTime.utc(2026, 4, 25, 10, 0, 30));
    });

    test('forwards lock-manager transitions to the broadcaster', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 0, 5),
      ]);
      final deps = await AppDeps.bootstrap(_config(tmp), clock: clock);
      addTearDown(deps.close);

      final received = <WsMessage>[];
      deps.broadcaster
        ..register('c1').listen(received.add)
        ..subscribe('c1', 'n1');

      await deps.lockManager.acquire(noteId: 'n1', actor: 'alice');
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect((received.single as LockEvent).noteId, 'n1');
      expect((received.single as LockEvent).holder, 'alice');
    });

    test('wires the OAuth stores under <dataDir>/oauth/', () async {
      final deps = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      expect(deps.clientStore.dir.path, '${tmp.path}/oauth/clients');
      expect(deps.codeStore.dir.path, '${tmp.path}/oauth/codes');
      expect(deps.tokenStore.dir.path, '${tmp.path}/oauth/tokens');
    });

    test('purges expired OAuth codes and tokens on bootstrap', () async {
      final bootClock = FixedClock.fixed(DateTime.utc(2026));
      final seed = await AppDeps.bootstrap(_config(tmp), clock: bootClock);
      addTearDown(seed.close);
      await seed.codeStore.mint(
        clientId: 'c1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        actor: 'a',
        grantId: 'g1',
      );
      await seed.tokenStore.issue(
        clientId: 'c1',
        actor: 'a',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        grantId: 'g1',
      );

      final logs = <LogRecord>[];
      final logger = Logger.detached('app_deps_test')
        ..onRecord.listen(logs.add);
      final reloaded = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 6)),
        logger: logger,
      );

      expect(
        Directory('${tmp.path}/oauth/codes').listSync(),
        isEmpty,
      );
      expect(
        Directory('${tmp.path}/oauth/tokens').listSync(),
        isEmpty,
      );
      expect(
        logs.any(
          (r) => r.message.contains('OAuth code') && r.message.contains('1'),
        ),
        isTrue,
      );
      expect(
        logs.any(
          (r) => r.message.contains('OAuth token') && r.message.contains('1'),
        ),
        isTrue,
      );
      addTearDown(reloaded.close);
    });

    test(
        'revoking a grant through tokenStore also revokes its outstanding '
        'authorization code', () async {
      final deps = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      addTearDown(deps.close);

      final code = await deps.codeStore.mint(
        clientId: 'c1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        actor: 'a',
        grantId: 'shared-grant',
      );
      await deps.tokenStore.issue(
        clientId: 'c1',
        actor: 'a',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        grantId: 'shared-grant',
      );

      await deps.tokenStore.revokeGrant('shared-grant');

      await expectLater(
        deps.codeStore.consume(code, (record) async => record),
        throwsA(isA<CodeNotFoundException>()),
      );
    });

    group('OIDC discovery', () {
      Config oidcConfig(Directory dir) => Config(
            apiKey: 'rn_test',
            dataDir: dir.path,
            port: 8080,
            lockTtlSeconds: 60,
            oidc: const OidcConfig(
              issuer: 'https://idp.example.com',
              clientId: 'robot-notes',
              clientSecret: 'shh',
            ),
          );

      Future<String> fakeDiscovery(Uri uri) async => jsonEncode({
            'issuer': 'https://idp.example.com',
            'authorization_endpoint': 'https://idp.example.com/authorize',
            'token_endpoint': 'https://idp.example.com/token',
            'jwks_uri': 'https://idp.example.com/jwks.json',
          });

      test('is not fetched when OIDC is not configured', () async {
        var called = false;
        final deps = await AppDeps.bootstrap(
          _config(tmp),
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
          oidcHttpGet: (uri) async {
            called = true;
            return fakeDiscovery(uri);
          },
        );
        addTearDown(deps.close);
        expect(called, isFalse);
        expect(deps.oidcDiscovery, isNull);
      });

      test('is fetched and exposed when OIDC is configured', () async {
        final deps = await AppDeps.bootstrap(
          oidcConfig(tmp),
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
          oidcHttpGet: fakeDiscovery,
        );
        addTearDown(deps.close);
        expect(deps.oidcDiscovery, isNotNull);
        expect(
          deps.oidcDiscovery!.authorizationEndpoint,
          'https://idp.example.com/authorize',
        );
      });

      test('a JWKS cache pointed at the discovered jwks_uri is exposed',
          () async {
        final deps = await AppDeps.bootstrap(
          oidcConfig(tmp),
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
          oidcHttpGet: fakeDiscovery,
        );
        addTearDown(deps.close);
        expect(deps.oidcJwks, isNotNull);
        expect(deps.oidcJwks!.jwksUri, 'https://idp.example.com/jwks.json');
      });

      test('the JWKS cache is null when OIDC is not configured', () async {
        final deps = await AppDeps.bootstrap(
          _config(tmp),
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
        );
        addTearDown(deps.close);
        expect(deps.oidcJwks, isNull);
      });

      test('a discovery failure fails bootstrap', () async {
        await expectLater(
          AppDeps.bootstrap(
            oidcConfig(tmp),
            clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
            oidcHttpGet: (uri) async => throw Exception('unreachable'),
          ),
          throwsA(isA<OidcDiscoveryException>()),
        );
      });
    });

    group('embedding provider', () {
      test('no embedding provider is wired when unconfigured', () async {
        final deps = await AppDeps.bootstrap(
          _config(tmp),
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
        );
        addTearDown(deps.close);

        expect(deps.noteWriteService.embeddingProvider, isNull);
        final db = sqlite3.open('${tmp.path}/search.db');
        final tables = db.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='note_vectors';",
        );
        db.close();
        expect(tables, isEmpty);
      });

      test(
          'an Ollama embedding provider is wired into NoteWriteService and '
          'SearchIndex when configured', () async {
        final deps = await AppDeps.bootstrap(
          _embeddingConfig(tmp),
          clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
        );
        addTearDown(deps.close);

        expect(
          deps.noteWriteService.embeddingProvider,
          isA<OllamaEmbeddingProvider>(),
        );
        final db = sqlite3.open('${tmp.path}/search.db');
        final tables = db.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='note_vectors';",
        );
        db.close();
        expect(tables, isNotEmpty);
      });
    });
  });

  group('app_deps_holder', () {
    setUp(debugResetAppDeps);
    tearDown(debugResetAppDeps);

    test('reading before setAppDeps throws StateError', () {
      expect(() => appDeps, throwsStateError);
    });

    test('setAppDeps then appDeps returns the installed instance', () async {
      final tmp = _tempDir();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final deps = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      setAppDeps(deps);
      expect(identical(appDeps, deps), isTrue);
    });

    test('setAppDeps with the same instance is idempotent', () async {
      final tmp = _tempDir();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final deps = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      setAppDeps(deps);
      expect(() => setAppDeps(deps), returnsNormally);
    });

    test('setAppDeps with a different instance throws StateError', () async {
      final tmp = _tempDir();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final deps1 = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      final deps2 = await AppDeps.bootstrap(
        _config(tmp),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25)),
      );
      setAppDeps(deps1);
      expect(() => setAppDeps(deps2), throwsStateError);
    });
  });
}
