import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-purge-test-');

void main() {
  late Directory tmp;

  setUp(() => tmp = _tempDir());
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('CodeStore.purgeExpired', () {
    test('deletes expired codes, keeps unexpired ones, returns the count',
        () async {
      final mintClock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
      final store = CodeStore(
        dir: Directory('${tmp.path}/codes'),
        clock: mintClock,
      );
      await store.mint(
        clientId: 'c1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        actor: 'a',
        grantId: 'g-expired',
      );

      final freshStore = CodeStore(
        dir: Directory('${tmp.path}/codes'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10, 30)),
      );
      await freshStore.mint(
        clientId: 'c1',
        redirectUri: 'https://agent.example/callback',
        codeChallenge: 'challenge',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        actor: 'a',
        grantId: 'g-fresh',
      );

      final purgingStore = CodeStore(
        dir: Directory('${tmp.path}/codes'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10, 30)),
      );
      final purged = await purgingStore.purgeExpired();
      expect(purged, 1);

      final remaining =
          Directory('${tmp.path}/codes').listSync().whereType<File>();
      expect(remaining, hasLength(1));
    });
  });

  group('TokenStore.purgeExpired', () {
    test('deletes expired tokens, keeps unexpired ones, returns the count',
        () async {
      final oldStore = TokenStore(
        dir: Directory('${tmp.path}/tokens'),
        clock: FixedClock.fixed(DateTime.utc(2026, 1, 1, 10)),
      );
      await oldStore.issue(
        clientId: 'c1',
        actor: 'a',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        grantId: 'g-expired',
      );

      final freshStore = TokenStore(
        dir: Directory('${tmp.path}/tokens'),
        clock: FixedClock.fixed(DateTime.utc(2026, 5, 26, 9, 50)),
      );
      await freshStore.issue(
        clientId: 'c1',
        actor: 'a',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        grantId: 'g-fresh',
      );

      // At purge time g-expired's access (accessTtl = 1h from
      // 2026-01-01 10:00) and refresh (refreshTtl = 30d) are both long
      // past, while g-fresh's pair (issued 10 minutes earlier) is not.
      final purgingStore = TokenStore(
        dir: Directory('${tmp.path}/tokens'),
        clock: FixedClock.fixed(DateTime.utc(2026, 5, 26, 10)),
      );
      final purged = await purgingStore.purgeExpired();
      expect(purged, 2);

      final remaining =
          Directory('${tmp.path}/tokens').listSync().whereType<File>();
      expect(remaining, hasLength(2));
    });
  });
}
