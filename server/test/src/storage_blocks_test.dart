import 'dart:convert';
import 'dart:io';

import 'package:server/src/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Storage storage;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('storage-blocks-');
    storage = Storage(contentDir: Directory('${tmp.path}/content'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('accepted maps persist through edits, moves and restart', () async {
    const body = '# Title\r\n\r\n𝄞 old\r\n\r\n# End';
    final note = await storage.create(
      title: 'A',
      content: body,
      properties: {'history': true},
    );
    final before = await storage.readBlockMap(note.id);
    await storage.update(
      id: note.id,
      title: 'A',
      content: body.replaceFirst('old', 'new'),
      ifMatch: 1,
      path: 'Moved',
    );
    storage = Storage(contentDir: storage.contentDir);

    final current = await storage.readBlockMap(note.id);

    expect(current.blocks.map((b) => b.id), before.blocks.map((b) => b.id));
    expect(current.blocks[1].revision, 2);
    expect(
      (await storage.read(note.id)).content,
      body.replaceFirst('old', 'new'),
    );
    expect(
      (await storage.readBlockMap(note.id, version: 1)).contentHash,
      before.contentHash,
    );
  });

  test('stale whole-note save leaves block identities unchanged', () async {
    final note = await storage.create(
      title: 'A',
      content: 'first',
      properties: {'history': true},
    );
    await storage.update(id: note.id, title: 'A', content: 'next', ifMatch: 1);
    final before = await storage.readBlockMap(note.id);

    await expectLater(
      storage.update(id: note.id, title: 'A', content: 'stale', ifMatch: 1),
      throwsA(isA<VersionConflictException>()),
    );

    expect((await storage.readBlockMap(note.id)).toJson(), before.toJson());
  });

  test('journal recovery publishes the same intended opaque IDs', () async {
    final note = await storage.create(
      title: 'A',
      content: 'one\n\ntwo',
      properties: {'history': true},
    );
    storage = Storage(
      contentDir: storage.contentDir,
      afterHistoryPublish: () async => throw StateError('crash'),
    );
    await expectLater(
      storage.update(
        id: note.id,
        title: 'A',
        content: 'one\n\ntwo\n\nnew',
        ifMatch: 1,
      ),
      throwsStateError,
    );
    final pending = Directory('${tmp.path}/content.history')
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('/pending.json'));
    final intent =
        jsonDecode(pending.readAsStringSync()) as Map<String, dynamic>;
    await expectLater(storage.readBlockMap(note.id), throwsStateError);
    storage = Storage(contentDir: storage.contentDir);

    expect((await storage.readBlockMap(note.id)).toJson(), intent['block_map']);
  });

  test('external rewrite preserves history and marks its map stale', () async {
    final note = await storage.create(
      title: 'A',
      content: 'accepted',
      properties: {'history': true},
    );
    final before = await storage.readBlockMap(note.id);
    final canonical = File('${tmp.path}/content/A.md');
    canonical.writeAsStringSync(
      canonical.readAsStringSync().replaceFirst('accepted', 'external'),
    );

    await expectLater(
      storage.readBlockMap(note.id),
      throwsA(isA<BlockMapUnavailableException>()),
    );

    expect(
      (await storage.readBlockMap(note.id, version: 1)).toJson(),
      before.toJson(),
    );
    await storage.update(
      id: note.id,
      title: 'A',
      content: 'supported save',
      ifMatch: 1,
    );
    final after = await storage.readBlockMap(note.id);
    expect(after.blocks.single.id, isNot(before.blocks.single.id));
    expect(after.ambiguousIds, [before.blocks.single.id]);
  });

  test('legacy revisions stay immutable until a new accepted save', () async {
    final note = await storage.create(title: 'A', content: 'legacy');
    await expectLater(
      storage.readBlockMap(note.id),
      throwsA(isA<BlockMapUnavailableException>()),
    );

    await storage.update(
      id: note.id,
      title: 'A',
      content: 'captured',
      ifMatch: 1,
      properties: {'history': true},
    );

    await expectLater(
      storage.readBlockMap(note.id, version: 1),
      throwsA(isA<BlockMapUnavailableException>()),
    );
    expect((await storage.readBlockMap(note.id)).blocks, hasLength(1));
  });

  test('deleted restore and purge establish new block identities', () async {
    final note = await storage.create(
      title: 'A',
      content: 'retained',
      properties: {'history': true},
    );
    final before = await storage.readBlockMap(note.id);
    await storage.delete(note.id);
    expect((await storage.readBlockMap(note.id, version: 2)).blocks, isEmpty);
    await storage.restoreRevision(note.id, 1, ifMatch: 2);
    final restored = await storage.readBlockMap(note.id);
    expect(restored.blocks.single.id, isNot(before.blocks.single.id));
    await storage.purgeHistory(note.id);
    await expectLater(
      storage.readBlockMap(note.id),
      throwsA(isA<BlockMapUnavailableException>()),
    );
    await storage.update(id: note.id, title: 'A', content: 'fresh', ifMatch: 3);
    expect(
      (await storage.readBlockMap(note.id)).blocks.single.id,
      isNot(restored.blocks.single.id),
    );
  });
}
