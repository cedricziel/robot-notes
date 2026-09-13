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

    test('path defaults to the vault root when omitted', () {
      final meta = NoteMeta.fromJson({
        'id': '01HXY00000000000000000000A',
        'title': 'Hello',
        'version': 1,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      expect(meta.path, '');
    });

    test('round-trips a nested path', () {
      final meta = NoteMeta(
        id: '01HXY00000000000000000000A',
        title: 'Hello',
        path: 'Projects/Alpha',
        version: 3,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      final back = NoteMeta.fromJson(meta.toJson());
      expect(back, equals(meta));
      expect(back.path, 'Projects/Alpha');
    });

    test('excerpt and tags default when omitted from the JSON', () {
      final meta = NoteMeta.fromJson({
        'id': '01HXY00000000000000000000A',
        'title': 'Hello',
        'version': 1,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      expect(meta.excerpt, '');
      expect(meta.tags, isEmpty);
    });

    test('round-trips excerpt and tags', () {
      final meta = NoteMeta(
        id: '01HXY00000000000000000000A',
        title: 'Hello',
        version: 3,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        excerpt: 'A short preview of the note body…',
        tags: const ['planning', 'urgent'],
      );
      final json = meta.toJson();
      expect(json['excerpt'], 'A short preview of the note body…');
      expect(json['tags'], ['planning', 'urgent']);
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

    test('path and tags default when omitted from the JSON', () {
      final note = Note.fromJson({
        'id': '01HXY00000000000000000000A',
        'title': 'Hello',
        'content': 'World',
        'version': 1,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      expect(note.path, '');
      expect(note.tags, isEmpty);
    });

    test('round-trips a nested path and computed tags', () {
      final note = Note(
        id: '01HXY00000000000000000000A',
        title: 'Hello',
        path: 'Projects/Alpha',
        content: '# Hello\n\nWorld.',
        version: 1,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        tags: const ['urgent', 'planning'],
      );
      final back = Note.fromJson(note.toJson());
      expect(back, equals(note));
      expect(back.path, 'Projects/Alpha');
      expect(back.tags, ['urgent', 'planning']);
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
