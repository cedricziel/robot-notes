import 'dart:io';

import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/proposals/proposal_service.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late Storage storage;
  late KnowledgePolicyStore policies;
  late NoteAuthorizationService authorization;
  late ProposalService service;
  late StoredNote note;
  var indexed = 0;
  final proposer = KnowledgePrincipal.agent(
    credentialId: 'worker',
    scopes: {'notes:read', 'knowledge:propose'},
  );
  final reviewer = KnowledgePrincipal.oauth(
    grantId: 'human',
    scopes: {'notes:read', 'knowledge:review'},
  );

  ProposalService build() => ProposalService(
        storage: storage,
        authorization: authorization,
        onAccepted: (note, actor, {required deleted}) async {
          indexed++;
        },
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('proposal-service-');
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    policies = KnowledgePolicyStore(file: File('${dir.path}/policy.json'));
    await policies.load();
    authorization = NoteAuthorizationService(
      store: policies,
      beforeMutation: storage.prepareHistory,
    );
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true),
    );
    note = await storage.create(
      title: 'A',
      content: 'first\n\nlast',
      properties: {'history': true},
    );
    indexed = 0;
    service = build();
  });
  tearDown(() async {
    await policies.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<ProposalRecord> submit({String key = 'one'}) async {
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    return withKnowledgePrincipal(
      proposer,
      () => service.submit(note.id, {
        'base_version': note.version,
        'operations': [
          {
            'type': 'replace',
            'block_id': block.id,
            'expected_revision': block.revision,
            'text': 'proposed\n',
          }
        ],
        'idempotency_key': key,
      }),
    );
  }

  Future<ProposalRecord> approve(ProposalRecord record) =>
      withKnowledgePrincipal(
        reviewer,
        () => service.decide(note.id, record.id, {
          'decision': 'approve',
          'record_revision': record.recordRevision,
        }),
      );

  test('proposer publishes nothing and review-only human accepts atomically',
      () async {
    final record = await submit();
    expect((await storage.read(note.id)).content, 'first\n\nlast');
    expect(indexed, 0);
    final accepted = await approve(record);
    expect(accepted.state, 'accepted');
    expect(accepted.acceptedVersion, 2);
    expect((await storage.read(note.id)).content, 'proposed\n\nlast');
    expect(
      (await storage.readProposalRecord(note.id, record.id)).state,
      'accepted',
    );
    expect(indexed, 1);
    await expectLater(
      approve(record),
      throwsA(isA<ProposalRecordConflictException>()),
    );
    expect((await storage.read(note.id)).version, 2);
  });

  test('known agent cannot review despite extra scopes or human actor label',
      () async {
    final record = await submit();
    final agent = KnowledgePrincipal.agent(
      credentialId: 'worker',
      scopes: {
        'notes:read',
        'knowledge:propose',
        'knowledge:review',
        'knowledge:edit',
        'notes:write',
      },
    );
    await expectLater(
      withKnowledgePrincipal(
        agent,
        () => service.decide(
          note.id,
          record.id,
          {'decision': 'approve', 'record_revision': 1},
          actor: 'Human reviewer',
        ),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    expect((await storage.read(note.id)).version, 1);
  });

  test('idempotent retries return one record and conflicting input is rejected',
      () async {
    final first = await submit();
    final second = await submit();
    expect(second.id, first.id);
    expect(await storage.proposalRecords(noteId: note.id), hasLength(1));
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    await expectLater(
      withKnowledgePrincipal(
        proposer,
        () => service.submit(note.id, {
          'base_version': 1,
          'operations': [
            {
              'type': 'delete',
              'block_id': block.id,
              'expected_revision': 1,
            }
          ],
          'idempotency_key': 'one',
        }),
      ),
      throwsA(isA<ProposalRecordConflictException>()),
    );
  });

  test('disjoint edits merge; overlapping edits require amendment', () async {
    final record = await submit();
    await storage.update(
      id: note.id,
      title: 'A',
      content: 'first\n\nother',
      ifMatch: 1,
    );
    final accepted = await approve(record);
    expect(accepted.acceptedVersion, 3);
    expect((await storage.read(note.id)).content, 'proposed\n\nother');
    note = await storage.read(note.id);
    final next = await submit(key: 'next');
    await storage.update(
      id: note.id,
      title: 'A',
      content: 'changed\n\nother',
      ifMatch: 3,
    );
    await expectLater(
      approve(next),
      throwsA(isA<ProposalRecordConflictException>()),
    );
    expect((await storage.read(note.id)).version, 4);
  });

  test('policy changes invalidate review instead of silently accepting',
      () async {
    final record = await submit();
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true, approval: 'evidence_no_conflict'),
    );
    await expectLater(
      approve(record),
      throwsA(isA<ProposalRecordConflictException>()),
    );
    expect(
      (await storage.readProposalRecord(note.id, record.id)).state,
      'needs_re_review',
    );
    expect((await storage.read(note.id)).version, 1);
  });

  test('new draft is discoverable but not a canonical placeholder', () async {
    final draft = await withKnowledgePrincipal(
      proposer,
      () => service.submitNew({
        'path': '',
        'title': 'Draft',
        'content': 'proposed new note',
        'idempotency_key': 'new',
      }),
    );
    await expectLater(
      storage.read(draft.noteId),
      throwsA(isA<NoteNotFoundException>()),
    );
    final items = await withKnowledgePrincipal(reviewer, () => service.list());
    expect(items.single['new_note'], isTrue);
    expect(items.single['title'], 'Draft');
    final detail = await withKnowledgePrincipal(
      reviewer,
      () => service.inspect(draft.noteId, draft.id),
    );
    expect((detail['draft'] as Map)['content'], 'proposed new note');
    expect(detail['allowed_actions'], contains('approve'));
    await withKnowledgePrincipal(
      reviewer,
      () => service.decide(
        draft.noteId,
        draft.id,
        {'decision': 'approve', 'record_revision': 1},
      ),
    );
    expect((await storage.read(draft.noteId)).content, 'proposed new note');
    expect(await storage.list(), hasLength(2));
  });

  test('path collisions preserve draft and accepted target unchanged',
      () async {
    final draft = await withKnowledgePrincipal(
      proposer,
      () => service.submitNew({
        'path': '',
        'title': 'A',
        'content': 'overwrite',
        'idempotency_key': 'new',
      }),
    );
    await expectLater(
      withKnowledgePrincipal(
        reviewer,
        () => service.decide(
          draft.noteId,
          draft.id,
          {'decision': 'approve', 'record_revision': 1},
        ),
      ),
      throwsA(isA<PathConflictException>()),
    );
    expect((await storage.read(note.id)).content, 'first\n\nlast');
    expect(
      (await storage.readProposalRecord(draft.noteId, draft.id)).state,
      'pending',
    );
  });

  test('interrupted acceptance hides reads and replays final decision once',
      () async {
    final record = await submit();
    storage = Storage(
      contentDir: Directory('${dir.path}/content'),
      afterHistoryPublish: () async => throw StateError('crash'),
    );
    service = build();
    await expectLater(approve(record), throwsStateError);
    await expectLater(
      storage.readProposalRecord(note.id, record.id),
      throwsStateError,
    );
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    final accepted = await storage.readProposalRecord(note.id, record.id);
    expect(accepted.state, 'accepted');
    expect(accepted.events.where((e) => e['type'] == 'approve'), hasLength(1));
    expect((await storage.read(note.id)).content, 'proposed\n\nlast');
    expect(storage.historyNeedsReindex, isTrue);
  });
  test('read alone cannot comment and human review can comment', () async {
    final record = await submit();
    final reader =
        KnowledgePrincipal.oauth(grantId: 'reader', scopes: {'notes:read'});
    await expectLater(
      withKnowledgePrincipal(
        reader,
        () => service.comment(
          note.id,
          record.id,
          {'record_revision': 1, 'body': 'read only'},
        ),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final updated = await withKnowledgePrincipal(
      reviewer,
      () => service.comment(note.id, record.id, {
        'record_revision': 1,
        'body': 'review context',
        'block_id': block.id,
        'block_revision': block.revision,
      }),
    );
    expect(updated.recordRevision, 2);
    expect(updated.comments.single['note_version'], 1);
  });

  test('accepted block comments need no proposal and retain stale threads',
      () async {
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final added = await withKnowledgePrincipal(
      reviewer,
      () => service.commentAccepted(note.id, {
        'record_revision': 0,
        'body': 'why?',
        'block_id': block.id,
        'block_revision': 1,
      }),
    );
    final comment = (added['items'] as List).single as Map;
    expect(await storage.proposalRecords(), isEmpty);
    await storage.update(
      id: note.id,
      title: 'A',
      content: 'changed\n\nlast',
      ifMatch: 1,
    );
    final stale = await withKnowledgePrincipal(
      reviewer,
      () => service.acceptedComments(note.id),
    );
    expect(((stale['items'] as List).single as Map)['anchor_status'], 'stale');
    final reply = await withKnowledgePrincipal(
      reviewer,
      () => service.commentAccepted(
        note.id,
        {
          'record_revision': 1,
          'body': 'answer',
          'reply_to': comment['comment_id'],
        },
      ),
    );
    expect(reply['items'] as List, hasLength(2));
    expect(
      ((reply['items'] as List).last as Map)['thread_id'],
      comment['thread_id'],
    );
    await expectLater(
      withKnowledgePrincipal(
        reviewer,
        () => service.commentAccepted(note.id, {
          'record_revision': 1,
          'body': 'stale activity',
          'block_id': block.id,
          'block_revision': 1,
        }),
      ),
      throwsA(isA<ProposalRecordConflictException>()),
    );
  });

  test('draft amendments retain earlier source and reserve the same note ID',
      () async {
    final draft = await withKnowledgePrincipal(
      proposer,
      () => service.submitNew({
        'path': '',
        'title': 'Draft',
        'content': 'first',
        'idempotency_key': 'new',
      }),
    );
    final amended = await withKnowledgePrincipal(
      proposer,
      () => service.amend(draft.noteId, draft.id, {
        'proposal_revision': 1,
        'record_revision': 1,
        'path': '',
        'title': 'Revised',
        'content': 'second',
      }),
    );
    expect(amended.noteId, draft.noteId);
    expect(amended.proposalRevision, 2);
    expect(
      (amended.versions.first.candidate['draft'] as Map)['content'],
      'first',
    );
    await withKnowledgePrincipal(
      reviewer,
      () => service.decide(
        amended.noteId,
        amended.id,
        {'decision': 'approve', 'record_revision': 2},
      ),
    );
    expect((await storage.read(draft.noteId)).title, 'Revised');
  });

  test(
      'automatic verified attachment changes linkage only, never accepted text',
      () async {
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true, approval: 'evidence_no_conflict'),
    );
    final source = await storage.create(
      title: 'Source',
      content: 'source text',
      properties: {'history': true},
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final accepted = await withKnowledgePrincipal(
      proposer,
      () => service.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'auto',
        'operations': [
          {
            'type': 'attach_evidence',
            'block_id': block.id,
            'expected_revision': 1,
            'evidence_refs': [
              {'kind': 'note_revision', 'note_id': source.id, 'version': 1},
            ],
          }
        ],
      }),
    );
    expect(accepted.state, 'accepted');
    expect((await storage.read(note.id)).content, 'first\n\nlast');
    expect((await storage.readBlockMap(note.id)).blocks.first.revision, 1);
    expect(accepted.events.any((e) => e['type'] == 'auto_approve'), isTrue);
    final provenance = await storage.readAcceptedProvenance(note.id);
    expect((provenance[block.id] as Map)['evidence_refs'], hasLength(1));
  });

  test('valid evidence never automatically accepts changed claim text',
      () async {
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true, approval: 'evidence_no_conflict'),
    );
    final source = await storage.create(
      title: 'Source',
      content: 'source text',
      properties: {'history': true},
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final record = await withKnowledgePrincipal(
      proposer,
      () => service.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'text',
        'operations': [
          {
            'type': 'replace',
            'block_id': block.id,
            'expected_revision': 1,
            'text': 'claim\n',
            'evidence_refs': [
              {'kind': 'note_revision', 'note_id': source.id, 'version': 1},
            ],
          }
        ],
      }),
    );
    expect(record.state, 'pending');
    expect((await storage.read(note.id)).version, 1);
  });

  test('unverified source attachment remains pending under automatic policy',
      () async {
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true, approval: 'evidence_no_conflict'),
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final record = await withKnowledgePrincipal(
      proposer,
      () => service.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'unknown',
        'operations': [
          {
            'type': 'attach_evidence',
            'block_id': block.id,
            'expected_revision': 1,
            'evidence_refs': [
              {'kind': 'conversation', 'session_id': 'session'},
            ],
          }
        ],
      }),
    );
    expect(record.state, 'pending');
    expect(indexed, 0);
  });

  test('source read ACL applies to referenced immutable evidence', () async {
    final source = await storage.create(
      title: 'Private',
      content: 'secret',
      path: 'private',
      properties: {'history': true},
    );
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'private',
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    await expectLater(
      withKnowledgePrincipal(
        proposer,
        () => service.submit(note.id, {
          'base_version': 1,
          'idempotency_key': 'denied',
          'operations': [
            {
              'type': 'attach_evidence',
              'block_id': block.id,
              'expected_revision': 1,
              'evidence_refs': [
                {'kind': 'note_revision', 'note_id': source.id, 'version': 1},
              ],
            }
          ],
        }),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    expect(await storage.proposalRecords(), isEmpty);
  });
  test('restoring before an automatic link removes active links, retains audit',
      () async {
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true, approval: 'evidence_no_conflict'),
    );
    final source = await storage.create(
      title: 'Source',
      content: 'evidence',
      properties: {'history': true},
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final accepted = await withKnowledgePrincipal(
      proposer,
      () => service.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'reversible',
        'operations': [
          {
            'type': 'attach_evidence',
            'block_id': block.id,
            'expected_revision': 1,
            'evidence_refs': [
              {'kind': 'note_revision', 'note_id': source.id, 'version': 1},
            ],
          }
        ],
      }),
    );
    expect(await storage.readAcceptedProvenance(note.id), isNotEmpty);
    await storage.restoreRevision(note.id, 1, ifMatch: 2);
    expect(await storage.readAcceptedProvenance(note.id), isEmpty);
    expect(
      await storage.readAcceptedProvenance(note.id, version: 2),
      isNotEmpty,
    );
    expect(
      (await storage.readProposalRecord(note.id, accepted.id)).state,
      'accepted',
    );
    final index = await withKnowledgePrincipal(
      reviewer,
      () => service.list(state: 'accepted'),
    );
    expect(index.single['proposal_id'], accepted.id);
  });
}
