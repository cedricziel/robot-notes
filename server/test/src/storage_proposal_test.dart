import 'dart:io';

import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

const author = ProposalAuthor(
  principalId: 'agent:writer',
  label: 'Writer',
  kind: 'agent',
);

void main() {
  late Directory dir;
  late Storage storage;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('proposal-storage-');
    storage = Storage(contentDir: Directory('${dir.path}/content'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> pending(String id, String blockId) async {
    await storage.writeProposalRecord(
      ProposalRecord.create(
        id: id,
        noteId: (await storage.list()).single.id,
        author: author,
        at: DateTime.utc(2026),
        candidate: {
          'base_version': 1,
          'operations': [
            {
              'type': 'replace',
              'block_id': blockId,
              'expected_revision': 1,
              'text': 'pending secret',
            }
          ],
        },
      ),
    );
  }

  test('pending records stay outside canonical listing and survive restart',
      () async {
    final note = await storage
        .create(title: 'A', content: 'accepted', properties: {'history': true});
    final block = (await storage.readBlockMap(note.id)).blocks.single;
    await pending('p1', block.id);
    expect((await storage.read(note.id)).content, 'accepted');
    expect(await storage.list(), hasLength(1));
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    expect((await storage.proposalRecords()).single.state, 'pending');
  });

  test('direct edits invalidate overlapping review and retain disjoint review',
      () async {
    final note = await storage.create(
      title: 'A',
      content: 'first\n\nsecond',
      properties: {'history': true},
    );
    final map = await storage.readBlockMap(note.id);
    await pending('first', map.blocks.first.id);
    await pending('second', map.blocks.last.id);
    await storage.update(
      id: note.id,
      title: 'A',
      content: 'changed\n\nsecond',
      ifMatch: 1,
    );
    expect(
      (await storage.readProposalRecord(note.id, 'first')).state,
      'needs_re_review',
    );
    expect(
      (await storage.readProposalRecord(note.id, 'second')).state,
      'pending',
    );
  });

  test('interrupted edit replays exactly one proposal invalidation', () async {
    final note = await storage
        .create(title: 'A', content: 'first', properties: {'history': true});
    final block = (await storage.readBlockMap(note.id)).blocks.single;
    await pending('p1', block.id);
    storage = Storage(
      contentDir: Directory('${dir.path}/content'),
      afterHistoryPublish: () async => throw StateError('crash'),
    );
    await storage.prepareHistory();
    await expectLater(
      storage.update(id: note.id, title: 'A', content: 'next', ifMatch: 1),
      throwsStateError,
    );
    await expectLater(
      storage.readProposalRecord(note.id, 'p1'),
      throwsStateError,
    );
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    final record = await storage.readProposalRecord(note.id, 'p1');
    expect(record.state, 'needs_re_review');
    expect(record.recordRevision, 2);
    expect(
      record.events.where((e) => e['type'] == 'invalidated'),
      hasLength(1),
    );
  });

  test('history purge erases pending review data', () async {
    final note = await storage
        .create(title: 'A', content: 'first', properties: {'history': true});
    final block = (await storage.readBlockMap(note.id)).blocks.single;
    await pending('p1', block.id);
    await storage.purgeHistory(note.id);
    expect(await storage.proposalRecords(), isEmpty);
  });
}
