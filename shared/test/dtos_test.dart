import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('Lock', () {
    test('round-trips through JSON', () {
      final lock = Lock(
        holder: 'alice',
        expiresAt: DateTime.utc(2026, 4, 25, 12, 0, 0),
      );
      final json = lock.toJson();
      expect(json, {
        'holder': 'alice',
        'expires_at': '2026-04-25T12:00:00.000Z',
      });
      final back = Lock.fromJson(json);
      expect(back, equals(lock));
    });
  });

  group('NoteMeta', () {
    test('round-trips through JSON without content or lock', () {
      final meta = NoteMeta(
        id: '01HXY00000000000000000000A',
        title: 'Hello',
        version: 3,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      final json = meta.toJson();
      expect(json.containsKey('content'), isFalse);
      expect(json.containsKey('lock'), isFalse);
      final back = NoteMeta.fromJson(json);
      expect(back, equals(meta));
    });
  });

  group('Note', () {
    test('round-trips through JSON with no lock', () {
      final note = Note(
        id: '01HXY00000000000000000000A',
        title: 'Hello',
        content: '# Hello\n\nWorld.',
        version: 1,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final back = Note.fromJson(note.toJson());
      expect(back, equals(note));
      expect(note.toJson()['lock'], isNull);
    });

    test('round-trips through JSON with a lock', () {
      final note = Note(
        id: '01HXY00000000000000000000B',
        title: 'Locked one',
        content: 'body',
        version: 5,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 5),
        lock: Lock(
          holder: 'bob',
          expiresAt: DateTime.utc(2026, 1, 5, 12, 30),
        ),
      );
      final back = Note.fromJson(note.toJson());
      expect(back, equals(note));
      expect(back.lock, isNotNull);
      expect(back.lock!.holder, 'bob');
    });
  });

  group('InviteSummary', () {
    test('round-trips with no burn timestamp', () {
      final inv = InviteSummary(
        token: 'tok_abc',
        label: 'research-bot',
        createdAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2026, 1, 2),
        expired: false,
      );
      final back = InviteSummary.fromJson(inv.toJson());
      expect(back, equals(inv));
      expect(inv.toJson()['burned_at'], isNull);
    });

    test('round-trips with a burn timestamp', () {
      final inv = InviteSummary(
        token: 'tok_def',
        label: '',
        createdAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2026, 1, 2),
        burnedAt: DateTime.utc(2026, 1, 1, 10, 0),
        expired: false,
      );
      final back = InviteSummary.fromJson(inv.toJson());
      expect(back, equals(inv));
      expect(back.burnedAt, isNotNull);
    });
  });
}
