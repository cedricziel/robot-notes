import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-token-store-test-');

TokenStore _store(Directory tmp, {Clock? clock}) {
  return TokenStore(
    dir: Directory('${tmp.path}/tokens'),
    clock: clock ?? FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
  );
}

Future<IssuedTokens> _issue(
  TokenStore store, {
  String clientId = 'client-1',
  String actor = 'desk-assistant',
  Set<String> scopes = const {'notes:read', 'notes:write'},
  String resource = 'https://notes.example/mcp',
  String grantId = 'grant-1',
}) {
  return store.issue(
    clientId: clientId,
    actor: actor,
    scopes: scopes,
    resource: resource,
    grantId: grantId,
  );
}

void main() {
  late Directory tmp;

  setUp(() => tmp = _tempDir());
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('TokenStore.issue', () {
    test('returns raw tokens and persists hashed records', () async {
      final store = _store(tmp);
      final issued = await _issue(store);

      final dir = Directory('${tmp.path}/tokens');
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(2));
      for (final file in files) {
        final raw = await file.readAsString();
        expect(raw.contains(issued.accessToken), isFalse);
        expect(raw.contains(issued.refreshToken!), isFalse);
      }
      expect(issued.expiresIn, TokenStore.accessTtl.inSeconds);
      expect(issued.scopes, {'notes:read', 'notes:write'});
    });

    test('access token is still valid just before accessTtl elapses', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10)
            .add(TokenStore.accessTtl)
            .subtract(const Duration(seconds: 1)),
      ]);
      final store = _store(tmp, clock: clock);
      final issued = await _issue(store);
      final record = await store.lookupAccess(issued.accessToken);
      expect(record, isNotNull);
    });

    test('withRefresh: false mints no refresh token and writes no file',
        () async {
      final store = _store(tmp);
      final issued = await store.issue(
        clientId: 'client-1',
        actor: 'desk-assistant',
        scopes: {'notes:read'},
        resource: 'https://notes.example/mcp',
        grantId: 'grant-1',
        withRefresh: false,
      );

      expect(issued.refreshToken, isNull);
      final files =
          Directory('${tmp.path}/tokens').listSync().whereType<File>();
      expect(files, hasLength(1));
      final record = await store.lookupAccess(issued.accessToken);
      expect(record, isNotNull);
    });
  });

  group('TokenStore.lookupAccess', () {
    test('rejects a refresh token presented as access', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      expect(await store.lookupAccess(issued.refreshToken!), isNull);
    });

    test('rejects an expired access token', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10).add(TokenStore.accessTtl * 2),
      ]);
      final store = _store(tmp, clock: clock);
      final issued = await _issue(store);
      expect(await store.lookupAccess(issued.accessToken), isNull);
    });

    test('rejects a revoked access token', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      await store.revokeToken(issued.accessToken);
      expect(await store.lookupAccess(issued.accessToken), isNull);
    });

    test('returns the record for a live access token', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      final record = await store.lookupAccess(issued.accessToken);
      expect(record, isNotNull);
      expect(record!.actor, 'desk-assistant');
      expect(record.grantId, 'grant-1');
    });

    test('returns null for an unknown token', () async {
      final store = _store(tmp);
      expect(await store.lookupAccess('does-not-exist'), isNull);
    });

    test(
        'a wrong-typed field throws a TypeError, which is treated like '
        'any other malformed file', () async {
      final logs = <LogRecord>[];
      final store = TokenStore(
        dir: Directory('${tmp.path}/tokens'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        logger: Logger.detached('test')..onRecord.listen(logs.add),
      );
      const rawToken = 'not-a-real-token';
      final dir = Directory('${tmp.path}/tokens')..createSync(recursive: true);
      File(
        '${dir.path}/${hashSecret(rawToken)}.json',
      ).writeAsStringSync('{"client_id":123}');

      expect(await store.lookupAccess(rawToken), isNull);
      expect(logs, isNotEmpty);
      expect(logs.single.level, Level.WARNING);
    });

    test(
        'finds a token written by a prior store instance pointed at the '
        'same directory', () async {
      final store1 = _store(tmp);
      final issued = await _issue(store1);

      final store2 = _store(tmp);
      final record = await store2.lookupAccess(issued.accessToken);
      expect(record, isNotNull);
      expect(record!.grantId, 'grant-1');
    });
  });

  group('TokenStore.lookupRefresh', () {
    test('rejects an access token presented as refresh', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      expect(await store.lookupRefresh(issued.accessToken), isNull);
    });

    test('returns null for a rotated refresh token', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      await store.rotateRefresh(issued.refreshToken);
      expect(await store.lookupRefresh(issued.refreshToken), isNull);
    });
  });

  group('TokenStore.rotateRefresh', () {
    test('returns new tokens and marks the old one rotated', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      final rotated = await store.rotateRefresh(issued.refreshToken);

      expect(rotated.accessToken, isNot(issued.accessToken));
      expect(rotated.refreshToken, isNot(issued.refreshToken));
      expect(await store.lookupRefresh(issued.refreshToken), isNull);
      expect(await store.lookupRefresh(rotated.refreshToken), isNotNull);
    });

    test('a second rotation of the same token throws reuse', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      await store.rotateRefresh(issued.refreshToken);

      expect(
        () => store.rotateRefresh(issued.refreshToken),
        throwsA(
          isA<RefreshReuseException>().having(
            (e) => e.grantId,
            'grantId',
            'grant-1',
          ),
        ),
      );
    });

    test('reuse revokes the whole grant family', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      final rotated = await store.rotateRefresh(issued.refreshToken);

      // Present the original (already-rotated) refresh token again.
      await expectLater(
        () => store.rotateRefresh(issued.refreshToken),
        throwsA(isA<RefreshReuseException>()),
      );

      // The access token minted by the legitimate rotation is also dead.
      expect(await store.lookupAccess(rotated.accessToken), isNull);
      expect(await store.lookupRefresh(rotated.refreshToken), isNull);
    });

    test('throws ScopeWideningException when scope grows', () async {
      final store = _store(tmp);
      final issued = await _issue(store, scopes: {'notes:read'});

      expect(
        () => store.rotateRefresh(
          issued.refreshToken,
          scopes: {'notes:read', 'notes:write'},
        ),
        throwsA(isA<ScopeWideningException>()),
      );
    });

    test('allows narrowing scope', () async {
      final store = _store(tmp);
      final issued = await _issue(store);
      final rotated = await store.rotateRefresh(
        issued.refreshToken,
        scopes: {'notes:read'},
      );
      expect(rotated.scopes, {'notes:read'});
    });

    test('throws TokenNotFoundException for an unknown refresh token',
        () async {
      final store = _store(tmp);
      expect(
        () => store.rotateRefresh('does-not-exist'),
        throwsA(isA<TokenNotFoundException>()),
      );
    });

    test('throws TokenNotFoundException for an expired refresh token',
        () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10).add(TokenStore.refreshTtl * 2),
      ]);
      final store = _store(tmp, clock: clock);
      final issued = await _issue(store);
      expect(
        () => store.rotateRefresh(issued.refreshToken),
        throwsA(isA<TokenNotFoundException>()),
      );
    });
  });

  group('TokenStore.revokeGrant', () {
    test('marks every unrevoked record of the grant', () async {
      final store = _store(tmp);
      final issued = await _issue(store);

      final count = await store.revokeGrant('grant-1');
      expect(count, 2);
      expect(await store.lookupAccess(issued.accessToken), isNull);
      expect(await store.lookupRefresh(issued.refreshToken), isNull);
    });

    test('does not touch records from another grant', () async {
      final store = _store(tmp);
      final issued1 = await _issue(store);
      final issued2 = await _issue(store, grantId: 'grant-2');

      await store.revokeGrant('grant-1');
      expect(await store.lookupAccess(issued1.accessToken), isNull);
      expect(await store.lookupAccess(issued2.accessToken), isNotNull);
    });

    test('invokes onGrantRevoked with the revoked grant id', () async {
      final notified = <String>[];
      final store = TokenStore(
        dir: Directory('${tmp.path}/tokens'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        onGrantRevoked: (grantId) async => notified.add(grantId),
      );
      await _issue(store);

      await store.revokeGrant('grant-1');
      expect(notified, ['grant-1']);
    });

    test('a reuse-triggered cascade also invokes onGrantRevoked', () async {
      final notified = <String>[];
      final store = TokenStore(
        dir: Directory('${tmp.path}/tokens'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        onGrantRevoked: (grantId) async => notified.add(grantId),
      );
      final issued = await _issue(store);
      await store.rotateRefresh(issued.refreshToken);

      await expectLater(
        () => store.rotateRefresh(issued.refreshToken),
        throwsA(isA<RefreshReuseException>()),
      );
      expect(notified, ['grant-1']);
    });

    test(
        'racing a rotateRefresh of the same grant never leaves a live '
        'token behind', () async {
      final store = _store(tmp);
      final issued = await _issue(store);

      // Whichever of these wins the race for the grant lock, the other
      // must observe its effect rather than a torn intermediate state:
      // either revokeGrant sees the freshly rotated pair too (because it
      // ran second), or rotateRefresh finds the token already revoked and
      // cascades again itself (because revokeGrant ran first).
      await Future.wait<void>([
        store.revokeGrant('grant-1'),
        store.rotateRefresh(issued.refreshToken).then<void>(
              (_) {},
              onError: (Object _) {},
            ),
      ]);

      final dir = Directory('${tmp.path}/tokens');
      final files = dir.listSync().whereType<File>();
      for (final file in files) {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (json['grant_id'] == 'grant-1') {
          expect(
            json['revoked_at'],
            isNotNull,
            reason: 'live token left behind: ${file.path}',
          );
        }
      }
    });
  });

  group('TokenStore.revokeToken', () {
    test('revoking an access token only revokes itself', () async {
      final store = _store(tmp);
      final issued = await _issue(store);

      await store.revokeToken(issued.accessToken);
      expect(await store.lookupAccess(issued.accessToken), isNull);
      expect(await store.lookupRefresh(issued.refreshToken), isNotNull);
    });

    test('revoking a refresh token cascades the whole grant', () async {
      final store = _store(tmp);
      final issued = await _issue(store);

      await store.revokeToken(issued.refreshToken);
      expect(await store.lookupAccess(issued.accessToken), isNull);
      expect(await store.lookupRefresh(issued.refreshToken), isNull);
    });

    test('revoking an unknown token is a no-op', () async {
      final store = _store(tmp);
      await store.revokeToken('does-not-exist');
    });

    test(
        'a clientId guard mismatch leaves the token untouched (RFC 7009 '
        '§2.1: a client may only revoke its own tokens)', () async {
      final store = _store(tmp);
      final issued = await _issue(store, clientId: 'client-a');

      await store.revokeToken(issued.refreshToken, clientId: 'client-b');

      expect(await store.lookupRefresh(issued.refreshToken), isNotNull);
      expect(await store.lookupAccess(issued.accessToken), isNotNull);
    });

    test('a matching clientId guard revokes as usual', () async {
      final store = _store(tmp);
      final issued = await _issue(store, clientId: 'client-a');

      await store.revokeToken(issued.refreshToken, clientId: 'client-a');

      expect(await store.lookupRefresh(issued.refreshToken), isNull);
      expect(await store.lookupAccess(issued.accessToken), isNull);
    });
  });
}
