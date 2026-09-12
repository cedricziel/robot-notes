import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/oauth/code_store.dart';
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

      final record = await store.consume(code);
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

      final record = await store.consume(code);
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

      await store.consume(code);
      expect(
        () => store.consume(code),
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
        () => store.consume('does-not-exist'),
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
        () => store.consume(code),
        throwsA(isA<CodeNotFoundException>()),
      );
    });
  });
}
