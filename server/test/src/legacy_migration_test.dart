import 'dart:io';

import 'package:server/src/frontmatter.dart';
import 'package:server/src/legacy_migration.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-migration-test-');

void _writeLegacy(
  Directory contentDir,
  String id, {
  required String title,
  String body = 'body',
}) {
  File('${contentDir.path}/$id.md').writeAsStringSync(
    '---\nid: $id\ntitle: "$title"\nversion: 1\n'
    'created_at: "2026-04-25T10:00:00.000Z"\n'
    'updated_at: "2026-04-25T10:00:00.000Z"\n---\n$body\n',
  );
}

void main() {
  late Directory tmp;
  late Directory content;

  setUp(() {
    tmp = _tempDir();
    content = Directory('${tmp.path}/content')..createSync(recursive: true);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('missing content dir is a no-op', () async {
    final missing = Directory('${tmp.path}/nope');
    expect(await migrateLegacyLayout(contentDir: missing), 0);
  });

  test('renames a legacy file to its title with path: "" added', () async {
    _writeLegacy(content, '01HXY0000000000000000000AB', title: 'Ideas');

    final migrated = await migrateLegacyLayout(contentDir: content);

    expect(migrated, 1);
    final target = File('${content.path}/Ideas.md');
    expect(target.existsSync(), isTrue);
    expect(
      File('${content.path}/01HXY0000000000000000000AB.md').existsSync(),
      isFalse,
    );
    final fm = parseFrontmatter(target.readAsStringSync());
    expect(fm.metadata['path'], '');
    expect(fm.metadata['id'], '01HXY0000000000000000000AB');
  });

  test('a file that already has a path key is left untouched', () async {
    File('${content.path}/01HXY0000000000000000000CD.md').writeAsStringSync(
      '---\nid: 01HXY0000000000000000000CD\ntitle: "Already"\n'
      'path: "Folder"\nversion: 1\n'
      'created_at: "2026-04-25T10:00:00.000Z"\n'
      'updated_at: "2026-04-25T10:00:00.000Z"\n---\nbody\n',
    );

    final migrated = await migrateLegacyLayout(contentDir: content);

    expect(migrated, 0);
    expect(
      File('${content.path}/01HXY0000000000000000000CD.md').existsSync(),
      isTrue,
    );
  });

  test('colliding titles among migrating files get (2), (3) suffixes',
      () async {
    _writeLegacy(content, '01HXY0000000000000000000AA', title: 'Ideas');
    _writeLegacy(content, '01HXY0000000000000000000BB', title: 'Ideas');
    _writeLegacy(content, '01HXY0000000000000000000CC', title: 'Ideas');

    final migrated = await migrateLegacyLayout(contentDir: content);

    expect(migrated, 3);
    expect(File('${content.path}/Ideas.md').existsSync(), isTrue);
    expect(File('${content.path}/Ideas (2).md').existsSync(), isTrue);
    expect(File('${content.path}/Ideas (3).md').existsSync(), isTrue);
  });

  test(
      'a legacy title colliding with an already-existing non-legacy note '
      'is de-duplicated against the full namespace, not overwritten', () async {
    // A note that is NOT part of this migration already occupies
    // "Ideas (2).md" — e.g. from a previous migration run, or a note
    // someone deliberately titled that way.
    File('${content.path}/Ideas (2).md').writeAsStringSync(
      '---\nid: 01HXYEXISTING000000000000\ntitle: "Ideas (2)"\n'
      'path: ""\nversion: 1\n'
      'created_at: "2026-04-25T10:00:00.000Z"\n'
      'updated_at: "2026-04-25T10:00:00.000Z"\n---\nORIGINAL CONTENT\n',
    );
    _writeLegacy(content, '01HXY0000000000000000000AA', title: 'Ideas');
    _writeLegacy(content, '01HXY0000000000000000000BB', title: 'Ideas');

    await migrateLegacyLayout(contentDir: content);

    // The pre-existing note must survive untouched.
    expect(
      File('${content.path}/Ideas (2).md').readAsStringSync(),
      contains('ORIGINAL CONTENT'),
    );
    // The two migrating legacy files must land on names that don't
    // collide with it.
    expect(File('${content.path}/Ideas.md').existsSync(), isTrue);
    expect(File('${content.path}/Ideas (3).md').existsSync(), isTrue);
  });

  test('files are processed in ascending id order', () async {
    // Write 'B' (higher id) first on disk, 'A' (lower id) second — order
    // of directory listing shouldn't matter, only id order should.
    _writeLegacy(content, '01HXY0000000000000000000ZZ', title: 'Same');
    _writeLegacy(content, '01HXY0000000000000000000AA', title: 'Same');

    await migrateLegacyLayout(contentDir: content);

    // The lower id ("AA") should win the unsuffixed name.
    final winner = parseFrontmatter(
      File('${content.path}/Same.md').readAsStringSync(),
    );
    expect(winner.metadata['id'], '01HXY0000000000000000000AA');
    final loser = parseFrontmatter(
      File('${content.path}/Same (2).md').readAsStringSync(),
    );
    expect(loser.metadata['id'], '01HXY0000000000000000000ZZ');
  });

  test('a single malformed file is logged and skipped, migration continues',
      () async {
    File('${content.path}/01HXYBROKEN0000000000000A.md').writeAsStringSync(
      '---\nbroken yaml: [\n---\n',
    );
    _writeLegacy(content, '01HXY0000000000000000000AA', title: 'Good');

    final migrated = await migrateLegacyLayout(contentDir: content);

    expect(migrated, 1);
    expect(File('${content.path}/Good.md').existsSync(), isTrue);
    // The broken file is left in its legacy form, not deleted or moved.
    expect(
      File('${content.path}/01HXYBROKEN0000000000000A.md').existsSync(),
      isTrue,
    );
  });

  test('a nested file is never treated as a migration candidate', () async {
    final nested = Directory('${content.path}/Folder')
      ..createSync(recursive: true);
    File('${nested.path}/01HXY0000000000000000000AA.md').writeAsStringSync(
      '---\nid: 01HXY0000000000000000000AA\ntitle: "Nested"\npath: '
      '"Folder"\nversion: 1\ncreated_at: "2026-04-25T10:00:00.000Z"\n'
      'updated_at: "2026-04-25T10:00:00.000Z"\n---\nbody\n',
    );

    final migrated = await migrateLegacyLayout(contentDir: content);

    expect(migrated, 0);
  });
}
