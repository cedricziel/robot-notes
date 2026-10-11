import 'dart:convert';
import 'dart:io';

import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late Storage storage;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('history-test-');
    storage = Storage(contentDir: Directory('${dir.path}/content'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('index acknowledgement keeps another pending note revision dirty',
      () async {
    final first = await storage.create(
      title: 'First',
      content: 'one',
      properties: {'history': true},
    );
    final second = await storage.create(
      title: 'Second',
      content: 'two',
      properties: {'history': true},
    );

    await storage.acknowledgeIndexedRevision(first.id, 1);

    expect(storage.historyNeedsReindex, isTrue);
    await storage.acknowledgeIndexedRevision(second.id, 1);
    expect(storage.historyNeedsReindex, isFalse);
  });

  test('newer index acknowledgement cannot clear an older unindexed revision',
      () async {
    final note = await storage.create(
      title: 'A',
      content: 'first',
      properties: {'history': true},
    );
    await storage.update(id: note.id, title: 'A', content: 'next', ifMatch: 1);

    await storage.acknowledgeIndexedRevision(note.id, 2);

    expect(storage.historyNeedsReindex, isTrue);
    await storage.acknowledgeIndexedRevision(note.id, 1);
    expect(storage.historyNeedsReindex, isFalse);
  });

  test('retains opted-in updates and restores as a new version', () async {
    final note = await storage
        .create(title: 'A', content: 'first', properties: {'history': true});
    await storage.update(
      id: note.id,
      title: 'A',
      content: 'second',
      ifMatch: 1,
    );
    final restored = await storage.restoreRevision(note.id, 1, ifMatch: 2);
    expect(restored.content, 'first');
    expect(restored.version, 3);
    expect(
      (await storage.revisions(note.id)).map((r) => r['version']),
      [1, 2, 3],
    );
  });

  test('ordinary notes do not retain content', () async {
    final note = await storage.create(title: 'A', content: 'first');
    await storage.delete(note.id);
    expect(await storage.revisions(note.id), isEmpty);
  });

  test('deletion survives restart and restoration preserves identity',
      () async {
    final note = await storage
        .create(title: 'A', content: 'first', properties: {'history': true});
    await storage.delete(note.id);
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    expect((await storage.revisions(note.id)).last['deleted'], true);
    final restored = await storage.restoreRevision(note.id, 1, ifMatch: 2);
    expect(restored.id, note.id);
    expect(restored.version, 3);
  });
  test('failed publication remains absent from history until recovery',
      () async {
    final note = await storage
        .create(title: 'A', content: 'first', properties: {'history': true});
    storage = Storage(
      contentDir: Directory('${dir.path}/content'),
      beforeHistoryApply: () async => throw StateError('crash'),
    );
    await expectLater(
      storage.update(id: note.id, title: 'B', content: 'next', ifMatch: 1),
      throwsStateError,
    );
    await expectLater(storage.revisions(note.id), throwsStateError);
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    final recovered = await storage.read(note.id);
    expect(recovered.title, 'B');
    expect(recovered.version, 2);
    expect((await storage.revisions(note.id)).length, 2);
    expect(File('${dir.path}/content/A.md').existsSync(), false);
    expect(storage.historyNeedsReindex, true);
  });

  test('purge erases history while live opt-in continues capture', () async {
    final note = await storage
        .create(title: 'A', content: 'first', properties: {'history': true});
    await storage.purgeHistory(note.id);
    expect(await storage.revisions(note.id), isEmpty);
    await storage.update(
      id: note.id,
      title: 'A',
      content: 'second',
      ifMatch: 1,
    );
    expect((await storage.revisions(note.id)).last['version'], 2);
  });

  test('restore does not overwrite another note at historical path', () async {
    final note = await storage
        .create(title: 'A', content: 'first', properties: {'history': true});
    await storage.delete(note.id);
    await storage.create(title: 'A', content: 'replacement');
    await expectLater(
      storage.restoreRevision(note.id, 1, ifMatch: 2),
      throwsA(isA<PathConflictException>()),
    );
  });

  test('history preserves available actor attribution', () async {
    final note = await storage.create(
      title: 'A',
      content: 'first',
      actor: 'alice',
      properties: {'history': true},
    );
    expect((await storage.revisions(note.id)).single['actor'], 'alice');
  });
  test('interrupted deletion recovers tombstone and invalidates stale search',
      () async {
    final note = await storage.create(
      title: 'A',
      content: 'secretword',
      properties: {'history': true},
    );
    final dbFile = File('${dir.path}/search.db');
    final index = await SearchIndex.open(dbFile: dbFile, storage: storage);
    index.close();
    storage = Storage(
      contentDir: Directory('${dir.path}/content'),
      beforeHistoryApply: () async => throw StateError('crash'),
    );
    await expectLater(storage.delete(note.id), throwsStateError);
    await expectLater(
      storage.create(title: 'Other', content: 'blocked'),
      throwsStateError,
    );
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    final recovered = await SearchIndex.open(dbFile: dbFile, storage: storage);
    addTearDown(recovered.close);
    expect(await recovered.search('secretword'), isEmpty);
    expect((await storage.revisions(note.id)).last['deleted'], true);
    expect(storage.historyNeedsReindex, false);
  });

  test('purging deleted history permanently removes restore source', () async {
    final note = await storage.create(
      title: 'A',
      content: 'first',
      properties: {'history': true},
    );
    await storage.delete(note.id);
    await storage.purgeHistory(note.id);
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    expect(await storage.revisions(note.id), isEmpty);
    await expectLater(
      storage.restoreRevision(note.id, 1, ifMatch: 2),
      throwsA(isA<NoteNotFoundException>()),
    );
  });

  test('stale restore leaves current accepted content unchanged', () async {
    final note = await storage.create(
      title: 'A',
      content: 'first',
      properties: {'history': true},
    );
    await storage.update(
      id: note.id,
      title: 'A',
      content: 'second',
      ifMatch: 1,
    );
    await expectLater(
      storage.restoreRevision(note.id, 1, ifMatch: 1),
      throwsA(isA<HistoryVersionConflictException>()),
    );
    expect((await storage.read(note.id)).content, 'second');
    expect((await storage.revisions(note.id)).length, 2);
  });
  test('restart finishes interrupted purge with residual snapshots', () async {
    final note = await storage.create(
      title: 'A',
      content: 'first',
      properties: {'history': true},
    );
    await storage.delete(note.id);
    final history = Directory('${dir.path}/content.history')
        .listSync()
        .whereType<Directory>()
        .where((directory) => File('${directory.path}/1.json').existsSync())
        .single;
    File('${history.path}.purge').writeAsStringSync('', flush: true);
    File('${history.path}/1.json').deleteSync();
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    expect(await storage.revisions(note.id), isEmpty);
    expect(File('${history.path}.purge').existsSync(), false);
  });
  test('post-publication failure hides uncommitted state until recovery',
      () async {
    final note = await storage.create(
      title: 'A',
      content: 'first',
      properties: {'history': true},
    );
    final dbFile = File('${dir.path}/search.db');
    final initial = await SearchIndex.open(dbFile: dbFile, storage: storage);
    initial.close();
    storage = Storage(
      contentDir: Directory('${dir.path}/content'),
      afterHistoryPublish: () async => throw StateError('crash'),
    );
    await expectLater(
      storage.update(
        id: note.id,
        title: 'A',
        content: 'nextword',
        ifMatch: 1,
      ),
      throwsStateError,
    );
    await expectLater(storage.read(note.id), throwsStateError);
    await expectLater(storage.revisions(note.id), throwsStateError);
    await expectLater(storage.list(), throwsStateError);
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    final recovered = await SearchIndex.open(dbFile: dbFile, storage: storage);
    addTearDown(recovered.close);
    expect((await storage.read(note.id)).version, 2);
    expect((await storage.revisions(note.id)).last['version'], 2);
    expect((await recovered.search('nextword')).single.id, note.id);
    expect(await recovered.search('first'), isEmpty);
    expect(storage.historyNeedsReindex, false);
  });
  test('mandatory live purge keeps exact current snapshot and block identities',
      () async {
    final note = await storage.create(title: 'Pinned', content: 'one');
    await storage.enableRevisionHistory(note.id);
    await storage.update(
      id: note.id,
      title: 'Pinned',
      content: 'two',
      ifMatch: 1,
    );
    final map = await storage.readBlockMap(note.id);
    final history = Directory(
      '${storage.contentDir.path}.history/${base64Url.encode(utf8.encode(note.id))}',
    );
    final current = await File('${history.path}/2.json').readAsString();
    await Directory('${history.path}/proposals').create();
    await File('${history.path}/proposals/candidate.json')
        .writeAsString('unaccepted');
    await storage.purgeHistory(note.id);
    expect(await File('${history.path}/2.json').readAsString(), current);
    expect((await storage.readBlockMap(note.id)).toJson(), map.toJson());
    expect(
      (await storage.revisions(note.id)).map((record) => record['version']),
      [2],
    );
    expect(Directory('${history.path}/proposals').existsSync(), false);
    await storage.delete(note.id);
    await storage.purgeHistory(note.id);
    expect(await storage.revisions(note.id), isEmpty);
  });

  test('restart replays a keep-version purge without regenerating block IDs',
      () async {
    final note = await storage.create(title: 'Pinned', content: 'one');
    await storage.enableRevisionHistory(note.id);
    await storage.update(
      id: note.id,
      title: 'Pinned',
      content: 'two',
      ifMatch: 1,
    );
    final history = Directory(
      '${storage.contentDir.path}.history/${base64Url.encode(utf8.encode(note.id))}',
    );
    final map = (await storage.readBlockMap(note.id)).toJson();
    final current = await File('${history.path}/2.json').readAsString();
    await File('${history.path}.purge')
        .writeAsString(jsonEncode({'keep_version': 2}), flush: true);
    storage = Storage(contentDir: storage.contentDir);
    await storage.prepareHistory();
    expect(await File('${history.path}/2.json').readAsString(), current);
    expect((await storage.readBlockMap(note.id)).toJson(), map);
    expect(
      (await storage.revisions(note.id)).map((record) => record['version']),
      [2],
    );
    expect(File('${history.path}.purge').existsSync(), false);
  });
}
