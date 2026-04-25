import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/invite_store.dart';
import 'package:test/test.dart';

class _SettableClock implements Clock {
  _SettableClock(this._now);

  DateTime _now;

  void set(DateTime now) => _now = now.toUtc();

  @override
  DateTime nowUtc() => _now.toUtc();
}

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-invite-test-');
}

InviteStore _store(
  Directory tmp, {
  Clock? clock,
  Random? random,
  Logger? logger,
}) {
  return InviteStore(
    inviteDir: Directory('${tmp.path}/invites'),
    clock: clock ?? FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    random: random,
    logger: logger,
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('InviteStore.mint', () {
    test('writes the invite file with the documented schema', () async {
      final clock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
      final store = _store(tmp, clock: clock);

      final invite = await store.mint(
        label: 'agent-alpha',
        ttl: const Duration(hours: 24),
      );

      expect(invite.label, 'agent-alpha');
      expect(invite.token, isNotEmpty);
      expect(invite.createdAt, DateTime.utc(2026, 4, 25, 10));
      expect(invite.expiresAt, DateTime.utc(2026, 4, 26, 10));
      expect(invite.burnedAt, isNull);

      final file = File('${tmp.path}/invites/${invite.token}.json');
      expect(file.existsSync(), isTrue);
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(json['token'], invite.token);
      expect(json['label'], 'agent-alpha');
      expect(json['burned_at'], isNull);
    });

    test('writes atomically: no .tmp leftover after success', () async {
      final store = _store(tmp);
      final invite = await store.mint(label: 'beta');

      final inviteDir = Directory('${tmp.path}/invites');
      final tmpFiles = inviteDir.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.tmp'),
          );
      expect(tmpFiles, isEmpty);
      expect(
        File('${tmp.path}/invites/${invite.token}.json').existsSync(),
        isTrue,
      );
    });

    test('mints URL-safe tokens with at least 128 bits of entropy', () async {
      // Use Random.secure() (the default) to verify entropy. We mint
      // a few hundred and assert no collisions and that the alphabet
      // is base64url-clean.
      final store = _store(tmp, clock: const Clock(), random: Random.secure());
      final urlSafe = RegExp(r'^[A-Za-z0-9_-]+$');
      final tokens = <String>{};
      for (var i = 0; i < 200; i++) {
        final invite = await store.mint(label: 'l$i');
        expect(
          urlSafe.hasMatch(invite.token),
          isTrue,
          reason: 'token ${invite.token} not URL-safe',
        );
        // 16 random bytes → base64url-without-padding ≈ ceil(16*8/6) = 22.
        expect(invite.token.length, greaterThanOrEqualTo(22));
        expect(
          tokens.add(invite.token),
          isTrue,
          reason: 'unexpected collision after $i mints',
        );
      }
    });

    test('rejects ttl_seconds > 30 days', () async {
      final store = _store(tmp);
      expect(
        () => store.mint(label: 'x', ttl: const Duration(days: 31)),
        throwsArgumentError,
      );
    });
  });

  group('InviteStore.list', () {
    test('returns all on-disk invites with the expired flag', () async {
      final clock = _SettableClock(DateTime.utc(2026, 4, 25, 10));
      final store = _store(tmp, clock: clock);

      final fresh = await store.mint(label: 'fresh');
      final stale = await store.mint(
        label: 'stale',
        ttl: const Duration(seconds: 1),
      );

      // Advance the clock past the stale invite's TTL.
      clock.set(DateTime.utc(2026, 4, 25, 11));

      final summaries = await store.list();
      final freshSummary = summaries.firstWhere((s) => s.token == fresh.token);
      final staleSummary = summaries.firstWhere((s) => s.token == stale.token);
      expect(freshSummary.expired, isFalse);
      expect(staleSummary.expired, isTrue);
    });

    test('skips and logs malformed JSON files', () async {
      final logger = Logger.detached('invite-test')..level = Level.ALL;
      final logged = <String>[];
      logger.onRecord.listen((rec) => logged.add(rec.message));

      final store = _store(tmp, logger: logger);
      final invite = await store.mint(label: 'good');

      File(
        '${tmp.path}/invites/garbage.json',
      ).writeAsStringSync('not valid json {');

      final summaries = await store.list();
      expect(summaries, hasLength(1));
      expect(summaries.single.token, invite.token);
      expect(logged.any((l) => l.contains('Skipping malformed')), isTrue);
    });
  });

  group('InviteStore.get', () {
    test('returns the invite when it exists', () async {
      final store = _store(tmp);
      final invite = await store.mint(label: 'alpha');
      final fetched = await store.get(invite.token);
      expect(fetched, isNotNull);
      expect(fetched!.token, invite.token);
      expect(fetched.label, 'alpha');
    });

    test('returns null when missing', () async {
      final store = _store(tmp);
      expect(await store.get('does-not-exist'), isNull);
    });
  });

  group('InviteStore.burn', () {
    test('returns the previous unburned state and stamps burned_at', () async {
      final clock = _SettableClock(DateTime.utc(2026, 4, 25, 10));
      final store = _store(tmp, clock: clock);
      final invite = await store.mint(label: 'a');

      clock.set(DateTime.utc(2026, 4, 25, 12));
      final previous = await store.burn(invite.token);
      expect(previous.burnedAt, isNull);

      final after = await store.get(invite.token);
      expect(after!.burnedAt, DateTime.utc(2026, 4, 25, 12));
    });

    test('throws AlreadyBurnedException on a second burn', () async {
      final store = _store(tmp);
      final invite = await store.mint(label: 'a');
      await store.burn(invite.token);
      await expectLater(
        () => store.burn(invite.token),
        throwsA(isA<AlreadyBurnedException>()),
      );
    });

    test('concurrent burns: exactly one succeeds, others see AlreadyBurned',
        () async {
      final store = _store(tmp);
      final invite = await store.mint(label: 'race');

      final results = await Future.wait<Object>([
        for (var i = 0; i < 8; i++)
          store.burn(invite.token).then<Object>(
                (inv) => 'ok',
                onError: (Object e) => e,
              ),
      ]);

      expect(results.where((r) => r == 'ok'), hasLength(1));
      expect(results.whereType<AlreadyBurnedException>(), hasLength(7));
    });

    test('burn of an unknown token throws InviteNotFoundException', () async {
      final store = _store(tmp);
      await expectLater(
        () => store.burn('nope'),
        throwsA(isA<InviteNotFoundException>()),
      );
    });
  });

  group('InviteStore.revoke', () {
    test('deletes the invite file', () async {
      final store = _store(tmp);
      final invite = await store.mint(label: 'r');
      await store.revoke(invite.token);
      expect(
        File('${tmp.path}/invites/${invite.token}.json').existsSync(),
        isFalse,
      );
    });

    test('revoke of an unknown token throws InviteNotFoundException', () async {
      final store = _store(tmp);
      await expectLater(
        () => store.revoke('nope'),
        throwsA(isA<InviteNotFoundException>()),
      );
    });
  });
}
