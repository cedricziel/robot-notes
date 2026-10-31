import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:http/http.dart' as http;
import 'package:server/src/actor.dart';
import 'package:server/src/auth_middleware.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:server/src/proposals/proposal_http.dart';
import 'package:server/src/proposals/proposal_mcp.dart';
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
  test('MCP exposes atomic accepted source and propose-only capabilities',
      () async {
    final registry = McpToolRegistry(proposalMcpTools(service));
    const principal = McpPrincipal(
      actor: 'Writer',
      principalId: 'agent:worker',
      isStaticKey: false,
      scopes: {'notes:read', 'knowledge:propose'},
    );
    final source =
        await registry.call('get_note_blocks', {'id': note.id}, principal);
    final data = source['structuredContent']! as Map;
    expect(data['content'], 'first\n\nlast');
    expect(data['offset_encoding'], 'utf-16');
    final block = (data['blocks'] as List).first as Map;
    final result = await registry.call(
      'propose_note_update',
      {
        'id': note.id,
        'base_version': 1,
        'idempotency_key': 'mcp',
        'operations': [
          {
            'type': 'replace',
            'block_id': block['id'],
            'expected_revision': block['revision'],
            'text': 'proposed\n',
          }
        ],
      },
      principal,
    );
    expect(result['isError'], isNull);
    expect((result['structuredContent']! as Map)['accepted'], isFalse);
    expect((await storage.read(note.id)).version, 1);
    final record = (await storage.proposalRecords()).single;
    expect(record.author.principalId, 'agent:worker');
    expect(record.author.label, 'Writer');
  });

  test('MCP review denies agent authority even when review scope is supplied',
      () async {
    final record = await submit();
    final registry = McpToolRegistry(proposalMcpTools(service));
    const principal = McpPrincipal(
      actor: 'Human',
      principalId: 'agent:worker',
      isStaticKey: false,
      scopes: {'notes:read', 'knowledge:review'},
    );
    final result = await registry.call(
      'review_note_proposal',
      {
        'id': note.id,
        'proposal_id': record.id,
        'decision': 'approve',
        'record_revision': 1,
      },
      principal,
    );
    expect(result['isError'], isTrue);
    expect((result['structuredContent']! as Map)['error'], 'forbidden');
    expect((await storage.read(note.id)).version, 1);
  });
  test('candidate history inspection requires read at every retained target',
      () async {
    final record = await submit();
    await storage.update(
      id: note.id,
      title: 'A',
      path: 'public',
      content: note.content,
      ifMatch: 1,
    );
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true, access: {KnowledgeAction.read: {}}),
    );
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'public',
      KnowledgePolicyPatch(
        access: {
          KnowledgeAction.read: {'*'},
        },
      ),
    );
    await expectLater(
      withKnowledgePrincipal(
        reviewer,
        () => service.inspect(note.id, record.id),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    final index = await withKnowledgePrincipal(reviewer, () => service.list());
    expect(index, isEmpty);
    final inspect = await withKnowledgePrincipal(
      const KnowledgePrincipal.operator(),
      () => service.inspect(note.id, record.id),
    );
    expect(inspect['versions'], hasLength(1));
  });
  test('archive loss after submission leaves durable pending review', () async {
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true, approval: 'evidence_no_conflict'),
    );
    var reads = 0;
    service = ProposalService(
      storage: storage,
      authorization: authorization,
      onAccepted: (note, actor, {required deleted}) async {
        indexed++;
      },
      archiveReader: (_) async =>
          ++reads <= 2 ? {'payload': 'stored evidence'} : null,
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final record = await withKnowledgePrincipal(
      proposer,
      () => service.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'archive-loss',
        'operations': [
          {
            'type': 'attach_evidence',
            'block_id': block.id,
            'expected_revision': 1,
            'evidence_refs': [
              {'kind': 'archive', 'digest': 'a' * 64},
            ],
          }
        ],
      }),
    );
    expect(record.state, 'pending');
    expect((await storage.read(note.id)).version, 1);
    expect(
      (await storage.readProposalRecord(note.id, record.id)).state,
      'pending',
    );
  });

  test('external source rewrite during evidence lookup cannot be overwritten',
      () async {
    var reads = 0;
    service = ProposalService(
      storage: storage,
      authorization: authorization,
      onAccepted: (note, actor, {required deleted}) async {
        indexed++;
      },
      archiveReader: (_) async {
        if (++reads == 2) {
          final file = File('${storage.contentDir.path}/A.md');
          await file.writeAsString(
            (await file.readAsString()).replaceFirst('first', 'external'),
          );
        }
        return {'payload': 'stored evidence'};
      },
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final record = await withKnowledgePrincipal(
      proposer,
      () => service.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'external',
        'operations': [
          {
            'type': 'replace',
            'block_id': block.id,
            'expected_revision': 1,
            'text': 'new\n',
            'evidence_refs': [
              {'kind': 'archive', 'digest': 'b' * 64},
            ],
          }
        ],
      }),
    );
    await expectLater(
      approve(record),
      throwsA(isA<BlockMapUnavailableException>()),
    );
    expect((await storage.read(note.id)).content, 'external\n\nlast');
    expect(
      (await storage.readProposalRecord(note.id, record.id)).state,
      'pending',
    );
    expect(indexed, 0);
  });
  test('institutional draft outside curated folder requires policy authority',
      () async {
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'ordinary',
      KnowledgePolicyPatch(curated: false),
    );
    storage.acceptedPolicyReplay = policies.replayAcceptedNoteDesignation;
    final draft = await withKnowledgePrincipal(
      proposer,
      () => service.submitNew({
        'path': 'ordinary',
        'title': 'Institutional',
        'content': 'draft',
        'idempotency_key': 'institutional',
      }),
    );
    final detail = await withKnowledgePrincipal(
      reviewer,
      () => service.inspect(draft.noteId, draft.id),
    );
    expect(detail['allowed_actions'], isNot(contains('approve')));
    await expectLater(
      withKnowledgePrincipal(
        reviewer,
        () => service.decide(
          draft.noteId,
          draft.id,
          {'decision': 'approve', 'record_revision': 1},
        ),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    final curator = KnowledgePrincipal.oauth(
      grantId: 'curator',
      scopes: {'notes:read', 'knowledge:review', 'knowledge:policy'},
    );
    await withKnowledgePrincipal(
      curator,
      () => service.decide(
        draft.noteId,
        draft.id,
        {'decision': 'approve', 'record_revision': 1},
      ),
    );
    expect(
      authorization.store
          .effective(
            KnowledgeTarget.note(
              draft.noteId,
              'ordinary',
            ),
          )
          .curated,
      isTrue,
    );
    expect((await storage.read(draft.noteId)).content, 'draft');
  });

  test('institutional crash replays policy and final record once', () async {
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'ordinary',
      KnowledgePolicyPatch(curated: false),
    );
    final draft = await withKnowledgePrincipal(
      proposer,
      () => service.submitNew({
        'path': 'ordinary',
        'title': 'Institutional',
        'content': 'draft',
        'idempotency_key': 'replay-designation',
      }),
    );
    final curator = KnowledgePrincipal.oauth(
      grantId: 'curator',
      scopes: {'notes:read', 'knowledge:review', 'knowledge:policy'},
    );
    final before = policies.revision;
    storage = Storage(
      contentDir: Directory('${dir.path}/content'),
      acceptedPolicyReplay: policies.replayAcceptedNoteDesignation,
      afterHistoryPublish: () async => throw StateError('crash'),
    );
    service = build();
    await expectLater(
      withKnowledgePrincipal(
        curator,
        () => service.decide(
          draft.noteId,
          draft.id,
          {'decision': 'approve', 'record_revision': 1},
        ),
      ),
      throwsStateError,
    );
    expect(policies.revision, before);
    storage = Storage(
      contentDir: Directory('${dir.path}/content'),
      acceptedPolicyReplay: policies.replayAcceptedNoteDesignation,
    );
    final accepted = await storage.readProposalRecord(draft.noteId, draft.id);
    expect(accepted.state, 'accepted');
    expect(policies.revision, before + 1);
    storage = Storage(
      contentDir: Directory('${dir.path}/content'),
      acceptedPolicyReplay: policies.replayAcceptedNoteDesignation,
    );
    await storage.prepareHistory();
    expect(policies.revision, before + 1);
  });
  test('restricted operator origin is audited and cannot approve manually',
      () async {
    const agentOperator = KnowledgePrincipal.operator(agentOrigin: true);
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final record = await withKnowledgePrincipal(
      agentOperator,
      () => service.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'marked-operator',
        'operations': [
          {
            'type': 'replace',
            'block_id': block.id,
            'expected_revision': 1,
            'text': 'new\n',
          },
        ],
      }),
    );
    expect(record.author.principalId, 'operator');
    expect(record.author.kind, 'operator');
    expect(record.summary()['author_agent_origin'], isTrue);
    await expectLater(
      withKnowledgePrincipal(
        agentOperator,
        () => service.decide(
          note.id,
          record.id,
          {'decision': 'approve', 'record_revision': 1},
        ),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    expect((await storage.read(note.id)).version, 1);
  });
  test('automatic marked-operator attachment is auditable as agent origin',
      () async {
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true, approval: 'evidence_no_conflict'),
    );
    final block = (await storage.readBlockMap(note.id)).blocks.first;
    final record = await withKnowledgePrincipal(
      const KnowledgePrincipal.operator(agentOrigin: true),
      () => service.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'agent-auto',
        'operations': [
          {
            'type': 'attach_evidence',
            'block_id': block.id,
            'expected_revision': 1,
            'evidence_refs': [
              {'kind': 'note_revision', 'note_id': note.id, 'version': 1},
            ],
          }
        ],
      }),
    );
    expect(record.state, 'accepted');
    expect(record.author.kind, 'operator');
    expect(record.author.agentOrigin, isTrue);
    final decision =
        record.events.singleWhere((event) => event['type'] == 'auto_approve');
    expect(decision['author_agent_origin'], isTrue);
    expect(decision['author_kind'], 'operator');
  });
  test('REST decision retains restrictive origin through its identity binding',
      () async {
    final record = await submit();
    final handler = ((RequestContext context) => proposalRequest(
              context,
              ProposalRoute.decisions,
              id: note.id,
              proposalId: record.id,
            ))
        .use(provider<ProposalService>((_) => service))
        .use(provider<Actor>((_) => const Actor('Human label')))
        .use(bearerAuth(configuredKey: 'test-key'));
    final server = await serve(handler, InternetAddress.loopbackIPv4, 0);
    try {
      final response = await http.post(
        Uri.parse(
          'http://127.0.0.1:${server.port}/notes/${note.id}/proposals/${record.id}/decisions',
        ),
        headers: {
          'Authorization': 'Bearer test-key',
          'X-Robot-Notes-Agent': 'true',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'decision': 'approve', 'record_revision': 1}),
      );
      expect(response.statusCode, 403, reason: response.body);
      expect((await storage.read(note.id)).version, 1);
      expect(
        (await storage.readProposalRecord(note.id, record.id)).state,
        'pending',
      );
    } finally {
      await server.close(force: true);
    }
  });
  test('compound replacement source links follow new accepted identities',
      () async {
    final compound = await storage.create(
      title: 'Compound',
      content: '- original\n\nlast',
      properties: {'history': true},
    );
    final oldBlock = (await storage.readBlockMap(compound.id)).blocks.first;
    final record = await withKnowledgePrincipal(
      proposer,
      () => service.submit(compound.id, {
        'base_version': 1,
        'idempotency_key': 'compound',
        'operations': [
          {
            'type': 'replace',
            'block_id': oldBlock.id,
            'expected_revision': 1,
            'text': '- changed\n',
            'evidence_refs': [
              {'kind': 'note_revision', 'note_id': note.id, 'version': 1},
            ],
            'supersedes': [
              {
                'kind': 'block_revision',
                'note_id': compound.id,
                'version': 1,
                'block_id': oldBlock.id,
                'block_revision': 1,
              }
            ],
          }
        ],
      }),
    );
    await withKnowledgePrincipal(
      reviewer,
      () => service.decide(
        compound.id,
        record.id,
        {'decision': 'approve', 'record_revision': 1},
      ),
    );
    final block = (await storage.readBlockMap(compound.id)).blocks.first;
    expect(block.id, isNot(oldBlock.id));
    final provenance = await storage.readAcceptedProvenance(compound.id);
    expect(provenance.containsKey(oldBlock.id), isFalse);
    final links = provenance[block.id] as Map;
    expect(links['evidence_refs'], hasLength(1));
    expect(
      ((links['supersedes'] as List).single as Map)['block_id'],
      oldBlock.id,
    );
    expect(links['source_unknown'], isFalse);
  });
  test(
      'unrelated note policy leaves a same-folder draft pending and approvable',
      () async {
    final draft = await withKnowledgePrincipal(
      proposer,
      () => service.submitNew({
        'path': '',
        'title': 'Runbook draft',
        'content': 'draft',
        'idempotency_key': 'unrelated-policy',
      }),
    );
    final before = draft.current.candidate['policy_revision'];
    await authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(note.id, ''),
      KnowledgePolicyPatch(approval: 'evidence_no_conflict'),
    );
    expect(policies.revision, isNot(before));
    final inspected = await withKnowledgePrincipal(
      reviewer,
      () => service.inspect(draft.noteId, draft.id),
    );
    expect(inspected['state'], 'pending');
    expect(inspected['record_revision'], 1);
    expect(inspected['allowed_actions'], contains('approve'));
    final accepted = await withKnowledgePrincipal(
      reviewer,
      () => service.decide(
        draft.noteId,
        draft.id,
        {'decision': 'approve', 'record_revision': 1},
      ),
    );
    expect(accepted.state, 'accepted');
  });

  test('proposers capture a baseline map for notes saved without history',
      () async {
    final ordinary =
        await storage.create(title: 'Plain', content: 'one\n\ntwo');
    await expectLater(
      withKnowledgePrincipal(
        reviewer,
        () => service.acceptedBlocks(ordinary.id),
      ),
      throwsA(isA<BlockMapUnavailableException>()),
    );

    final blocks = await withKnowledgePrincipal(
      proposer,
      () => service.acceptedBlocks(ordinary.id),
    );
    expect(blocks['version'], ordinary.version);
    expect(blocks['content'], 'one\n\ntwo');
    final last = (blocks['blocks'] as List).cast<Map<String, dynamic>>().last;

    final record = await withKnowledgePrincipal(
      proposer,
      () => service.submit(ordinary.id, {
        'base_version': ordinary.version,
        'idempotency_key': 'append',
        'operations': [
          {
            'type': 'insert_after',
            'block_id': last['id'],
            'expected_revision': last['revision'],
            'text': 'three\n',
          }
        ],
      }),
    );

    expect(record.state, 'pending');
    final current = await storage.read(ordinary.id);
    expect(current.version, ordinary.version);
    expect(current.content, 'one\n\ntwo');
  });
}
