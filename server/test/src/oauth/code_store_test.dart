import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-code-store-test-');

CodeStore _store(Directory tmp, {Clock? clock}) {
  return CodeStore(
    dir: Directory('${tmp.path}/codes'),
    clock: clock ?? FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
  );
}

void main() {
  late Directory tmp;

  setUp(() => tmp = _tempDir());
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('CodeStore.mint', () {
    test('returns a raw code and persists only its hash', () async {
      final store = _store(tmp);
      final code = await store.mint(
        clientId: 'client-1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read', 'notes:write'},
        resource: 'https://notes.example/mcp',
        actor: 'desk-assistant',
        grantId: 'grant-1',
      );

      final dir = Directory('${tmp.path}/codes');
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      final raw = await files.single.readAsString();
      expect(raw.contains(code), isFalse);
    });

    test('the record keeps every bound field', () async {
      final store = _store(tmp);
      final code = await store.mint(
        clientId: 'client-1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read', 'notes:write'},
        resource: 'https://notes.example/mcp',
        actor: 'desk-assistant',
        grantId: 'grant-1',
      );

      final record = await store.consume(code, (code) async => code);
      expect(record.clientId, 'client-1');
      expect(record.redirectUri, 'https://agent.example/callback');
      expect(record.codeChallenge, 'challenge');
      expect(record.scopes, {'notes:read', 'notes:write'});
      expect(record.resource, 'https://notes.example/mcp');
      expect(record.actor, 'desk-assistant');
      expect(record.grantId, 'grant-1');
    });
  });

  group('CodeStore.consume', () {
    test('returns the record once', () async {
      final store = _store(tmp);
      final code = await store.mint(
        clientId: 'client-1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        actor: 'desk-assistant',
        grantId: 'grant-1',
      );

      final record = await store.consume(code, (code) async => code);
      expect(record.consumedAt, isNotNull);
    });

    test('throws CodeReusedException on the second call', () async {
      final store = _store(tmp);
      final code = await store.mint(
        clientId: 'client-1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        actor: 'desk-assistant',
        grantId: 'grant-1',
      );

      await store.consume(code, (code) async => code);
      expect(
        () => store.consume(code, (code) async => code),
        throwsA(
          isA<CodeReusedException>().having(
            (e) => e.grantId,
            'grantId',
            'grant-1',
          ),
        ),
      );
    });

    test('throws CodeNotFoundException for an unknown code', () async {
      final store = _store(tmp);
      expect(
        () => store.consume('does-not-exist', (code) async => code),
        throwsA(isA<CodeNotFoundException>()),
      );
    });

    test('throws CodeNotFoundException for an expired code', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 20),
      ]);
      final store = _store(tmp, clock: clock);
      final code = await store.mint(
        clientId: 'client-1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        actor: 'desk-assistant',
        grantId: 'grant-1',
      );

      expect(
        () => store.consume(code, (code) async => code),
        throwsA(isA<CodeNotFoundException>()),
      );
    });

    test(
        'a concurrent second consume blocks until the first callback '
        'completes, then throws reuse', () async {
      final store = _store(tmp);
      final code = await store.mint(
        clientId: 'client-1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        actor: 'desk-assistant',
        grantId: 'grant-1',
      );
      final firstCallbackGate = Completer<void>();
      final firstCallbackEntered = Completer<void>();

      final firstFuture = store.consume(code, (record) async {
        firstCallbackEntered.complete();
        await firstCallbackGate.future;
        return 'first-result';
      });

      // Wait for the first call to be inside its callback (holding the
      // mutex) before starting the second.
      await firstCallbackEntered.future;

      final secondFuture = store.consume(
        code,
        (record) async => 'second-result',
      );
      var secondSettled = false;
      // Attach handlers now (not later) so a would-be-unhandled rejection
      // is never reported as such by the test runner, independent of when
      // `expectLater` below actually awaits it.
      unawaited(
        secondFuture.then(
          (_) => secondSettled = true,
          onError: (Object _) => secondSettled = true,
        ),
      );
      // Give the second call ample real time to run its own file I/O to
      // completion (a single `Duration.zero` pump is not enough — it would
      // pass even if the mutex leaked early, since the second call's own
      // async file reads take a few event-loop turns regardless). It must
      // still be blocked on the mutex, since the first callback has not
      // returned yet.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(secondSettled, isFalse);

      firstCallbackGate.complete();
      expect(await firstFuture, 'first-result');
      await expectLater(
        secondFuture,
        throwsA(
          isA<CodeReusedException>().having(
            (e) => e.grantId,
            'grantId',
            'grant-1',
          ),
        ),
      );
    });

    test(
        'a wrong-typed field throws a TypeError, which is treated like '
        'any other malformed file', () async {
      final logs = <LogRecord>[];
      final store = CodeStore(
        dir: Directory('${tmp.path}/codes'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        logger: Logger.detached('test')..onRecord.listen(logs.add),
      );
      const rawCode = 'not-a-real-code';
      final dir = Directory('${tmp.path}/codes')..createSync(recursive: true);
      File(
        '${dir.path}/${hashSecret(rawCode)}.json',
      ).writeAsStringSync('{"client_id":123}');

      await expectLater(
        store.consume(rawCode, (record) async => record),
        throwsA(isA<CodeNotFoundException>()),
      );
      expect(logs, isNotEmpty);
      expect(logs.single.level, Level.WARNING);
    });
  });

  group('CodeStore.revokeGrant', () {
    Future<String> mintFor(CodeStore store, String grantId) => store.mint(
          clientId: 'client-1',
          redirectUri: 'https://agent.example/callback',
          codeChallenge: 'challenge',
          scopes: {'notes:read'},
          resource: 'https://notes.example/mcp',
          actor: 'desk-assistant',
          grantId: grantId,
        );

    test('marks an outstanding code of the grant consumed, not exchangeable',
        () async {
      final store = _store(tmp);
      final code = await mintFor(store, 'grant-1');

      final count = await store.revokeGrant('grant-1');
      expect(count, 1);

      await expectLater(
        store.consume(code, (record) async => record),
        throwsA(isA<CodeNotFoundException>()),
      );
    });

    test('does not touch codes from another grant', () async {
      final store = _store(tmp);
      final untouched = await mintFor(store, 'grant-2');
      await mintFor(store, 'grant-1');

      await store.revokeGrant('grant-1');
      final record = await store.consume(untouched, (record) async => record);
      expect(record.grantId, 'grant-2');
    });

    test('is a no-op for an already-consumed code', () async {
      final store = _store(tmp);
      final code = await mintFor(store, 'grant-1');
      await store.consume(code, (record) async => record);

      final count = await store.revokeGrant('grant-1');
      expect(count, 0);
    });

    test('is a no-op when nothing was ever minted for the grant', () async {
      final store = _store(tmp);
      expect(await store.revokeGrant('no-such-grant'), 0);
    });
  });
}
