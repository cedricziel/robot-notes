import 'dart:io';

import 'package:server/src/app_deps.dart';
import 'package:server/src/app_deps_holder.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:shared/shared.dart';
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
