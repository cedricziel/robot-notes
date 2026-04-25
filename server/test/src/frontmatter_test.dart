import 'package:server/src/frontmatter.dart';
import 'package:test/test.dart';

void main() {
  group('parseFrontmatter', () {
    test('returns metadata map and body for a normal note', () {
      const text = '''
---
id: 01ARZ3NDEKTSV4RRFFQ69G5FAV
title: My note
version: 3
created_at: 2026-04-25T10:00:00Z
updated_at: 2026-04-25T10:30:00Z
---
# Hello

Body content here.
''';
      final fm = parseFrontmatter(text);
      expect(fm.metadata['id'], '01ARZ3NDEKTSV4RRFFQ69G5FAV');
      expect(fm.metadata['title'], 'My note');
      expect(fm.metadata['version'], 3);
      expect(fm.metadata['created_at'], '2026-04-25T10:00:00Z');
      expect(fm.metadata['updated_at'], '2026-04-25T10:30:00Z');
      expect(fm.body, '# Hello\n\nBody content here.\n');
    });

    test('returns empty metadata and full body when no frontmatter', () {
      const text = 'no frontmatter here\njust body\n';
      final fm = parseFrontmatter(text);
      expect(fm.metadata, isEmpty);
      expect(fm.body, text);
    });

    test('returns empty metadata when first line is not exactly ---', () {
      const text = '----\nid: x\n----\nbody\n';
      final fm = parseFrontmatter(text);
      expect(fm.metadata, isEmpty);
      expect(fm.body, text);
    });

    test('returns empty metadata when content is just whitespace', () {
      final fm = parseFrontmatter('');
      expect(fm.metadata, isEmpty);
      expect(fm.body, '');
    });

    test('parses an empty frontmatter block as empty metadata', () {
      const text = '---\n---\nbody\n';
      final fm = parseFrontmatter(text);
      expect(fm.metadata, isEmpty);
      expect(fm.body, 'body\n');
    });

    test('preserves frontmatter key order on parse', () {
      const text = '---\nz: 1\na: 2\nm: 3\n---\n';
      final fm = parseFrontmatter(text);
      expect(fm.metadata.keys.toList(), ['z', 'a', 'm']);
    });

    test('throws FrontmatterFormatException on missing closing delimiter', () {
      const text = '---\nid: x\nbody but no closing fence\n';
      expect(
        () => parseFrontmatter(text),
        throwsA(isA<FrontmatterFormatException>()),
      );
    });

    test('throws FrontmatterFormatException on malformed YAML', () {
      const text = '---\nid: x\n  bad indent here:\n   nested: [\n---\nbody\n';
      expect(
        () => parseFrontmatter(text),
        throwsA(isA<FrontmatterFormatException>()),
      );
    });

    test('throws when frontmatter root is not a map', () {
      const text = '---\n- one\n- two\n---\nbody\n';
      expect(
        () => parseFrontmatter(text),
        throwsA(isA<FrontmatterFormatException>()),
      );
    });

    test('preserves list-valued unknown keys', () {
      const text = '---\nid: x\ntags:\n  - planning\n  - ideas\n---\nbody\n';
      final fm = parseFrontmatter(text);
      expect(fm.metadata['tags'], ['planning', 'ideas']);
    });
  });

  group('serializeFrontmatter', () {
    test('emits frontmatter delimiters and body', () {
      const fm = Frontmatter(
        metadata: {'id': 'abc', 'title': 'My note', 'version': 1},
        body: 'Hello world\n',
      );
      final text = serializeFrontmatter(fm);
      expect(text.startsWith('---\n'), isTrue);
      final parts = text.split('\n---\n');
      expect(parts.length, 2);
      expect(parts[1], 'Hello world\n');
    });

    test('omits frontmatter when metadata is empty', () {
      const fm = Frontmatter(metadata: {}, body: 'just body\n');
      expect(serializeFrontmatter(fm), 'just body\n');
    });

    test('quotes string values', () {
      const fm = Frontmatter(
        metadata: {'title': 'has: colon'},
        body: '',
      );
      final text = serializeFrontmatter(fm);
      expect(text, contains('title: "has: colon"'));
    });

    test('escapes embedded double-quotes and backslashes in strings', () {
      const fm = Frontmatter(
        metadata: {'title': r'with "quotes" and \backslash'},
        body: '',
      );
      final text = serializeFrontmatter(fm);
      expect(text, contains(r'title: "with \"quotes\" and \\backslash"'));
    });

    test('emits integers as bare scalars', () {
      const fm = Frontmatter(metadata: {'version': 7}, body: '');
      final text = serializeFrontmatter(fm);
      expect(text, contains('version: 7'));
    });

    test('emits booleans as bare scalars', () {
      const fm = Frontmatter(metadata: {'flag': true}, body: '');
      expect(serializeFrontmatter(fm), contains('flag: true'));
    });

    test('emits null as ~', () {
      const fm = Frontmatter(metadata: {'lock': null}, body: '');
      expect(serializeFrontmatter(fm), contains('lock: ~'));
    });

    test('emits lists in block style', () {
      const fm = Frontmatter(
        metadata: {
          'tags': ['planning', 'ideas'],
        },
        body: '',
      );
      final text = serializeFrontmatter(fm);
      expect(text, contains('tags:'));
      expect(text, contains('  - "planning"'));
      expect(text, contains('  - "ideas"'));
    });
  });

  group('round-trip', () {
    test('serialize → parse preserves required keys and body', () {
      const original = Frontmatter(
        metadata: {
          'id': '01ARZ3NDEKTSV4RRFFQ69G5FAV',
          'title': 'My note',
          'version': 3,
          'created_at': '2026-04-25T10:00:00Z',
          'updated_at': '2026-04-25T10:30:00Z',
        },
        body: '# Hello\n\nBody.\n',
      );
      final text = serializeFrontmatter(original);
      final parsed = parseFrontmatter(text);
      expect(parsed.metadata, original.metadata);
      expect(parsed.body, original.body);
    });

    test('parse → serialize preserves key order and unknown keys', () {
      const text = '''
---
id: x
title: T
version: 1
created_at: 2026-04-25T00:00:00Z
updated_at: 2026-04-25T00:00:00Z
tags:
  - planning
  - ideas
custom_field: hello
---
body content
''';
      final fm = parseFrontmatter(text);
      final emitted = serializeFrontmatter(fm);
      final reparsed = parseFrontmatter(emitted);
      expect(reparsed.metadata.keys.toList(), [
        'id',
        'title',
        'version',
        'created_at',
        'updated_at',
        'tags',
        'custom_field',
      ]);
      expect(reparsed.metadata['tags'], ['planning', 'ideas']);
      expect(reparsed.metadata['custom_field'], 'hello');
      expect(reparsed.body, fm.body);
    });
  });
}
