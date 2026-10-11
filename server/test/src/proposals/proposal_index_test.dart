import 'dart:io';

import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/proposals/proposal_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late Storage storage;
  late SearchIndex search;
  late MetaIndex meta;
  late LinkIndex links;
  late Broadcaster broadcaster;
  late NoteWriteService writer;
  late KnowledgePolicyStore policies;
  late ProposalService proposals;
  late StoredNote note;
  final proposer = KnowledgePrincipal.agent(
    credentialId: 'writer',
    scopes: {'notes:read', 'knowledge:propose'},
  );
  final reviewer = KnowledgePrincipal.oauth(
    grantId: 'reviewer',
    scopes: {'notes:read', 'knowledge:review'},
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('proposal-index-');
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    search = await SearchIndex.open(
      dbFile: File('${dir.path}/search.db'),
      storage: storage,
    );
    meta = MetaIndex();
    links = LinkIndex();
    broadcaster = Broadcaster();
    writer = NoteWriteService(
      storage: storage,
      searchIndex: search,
      metaIndex: meta,
      linkIndex: links,
      broadcaster: broadcaster,
    );
    policies = KnowledgePolicyStore(file: File('${dir.path}/policy.json'));
    await policies.load();
    final authorization = NoteAuthorizationService(store: policies);
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      '',
      KnowledgePolicyPatch(curated: true),
    );
    proposals = ProposalService(
      storage: storage,
      authorization: authorization,
      onAccepted: writer.indexAcceptedProposal,
      validateDraft: writer.validateProposalDraft,
    );
    note = await withKnowledgePrincipal(
      const KnowledgePrincipal.operator(),
      () => writer.create(
        title: 'A',
        content: 'acceptedword',
        actor: 'setup',
        properties: {'history': true},
      ),
    );
  });
  tearDown(() async {
    search.close();
    await broadcaster.close();
    await policies.dispose();
    dir.deleteSync(recursive: true);
  });

  test('pending text and links enter normal indexes only after real acceptance',
      () async {
    final block = (await storage.readBlockMap(note.id)).blocks.single;
    final proposal = await withKnowledgePrincipal(
      proposer,
      () => proposals.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'replace',
        'operations': [
          {
            'type': 'replace',
            'block_id': block.id,
            'expected_revision': 1,
            'text': 'pendingsecret [[Target]]',
          }
        ],
      }),
    );
    expect(await search.search('pendingsecret'), isEmpty);
    expect(links.outgoing(note.id), isEmpty);
    expect(meta.get(note.id)!.version, 1);
    await withKnowledgePrincipal(
      reviewer,
      () => proposals.decide(
        note.id,
        proposal.id,
        {'decision': 'approve', 'record_revision': 1},
      ),
    );
    expect((await search.search('pendingsecret')).single.id, note.id);
    expect(links.outgoing(note.id).single.targetTitle, 'Target');
    expect(meta.get(note.id)!.version, 2);
    expect(storage.historyNeedsReindex, isFalse);
  });

  test('draft creates no indexed placeholder until committed acceptance',
      () async {
    final proposal = await withKnowledgePrincipal(
      proposer,
      () => proposals.submitNew({
        'path': '',
        'title': 'Draft',
        'content': 'draftsecret [[Target]]',
        'idempotency_key': 'draft',
      }),
    );
    expect(meta.get(proposal.noteId), isNull);
    expect(await search.search('draftsecret'), isEmpty);
    expect(links.outgoing(proposal.noteId), isEmpty);
    await withKnowledgePrincipal(
      reviewer,
      () => proposals.decide(
        proposal.noteId,
        proposal.id,
        {'decision': 'approve', 'record_revision': 1},
      ),
    );
    expect(meta.get(proposal.noteId)!.title, 'Draft');
    expect((await search.search('draftsecret')).single.id, proposal.noteId);
    expect(links.outgoing(proposal.noteId).single.targetTitle, 'Target');
  });

  test('reviewed deletion removes accepted index state and retains tombstone',
      () async {
    final proposal = await withKnowledgePrincipal(
      proposer,
      () => proposals.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'delete',
        'operations': [
          {'type': 'delete_note'},
        ],
      }),
    );
    expect(await search.search('acceptedword'), hasLength(1));
    final accepted = await withKnowledgePrincipal(
      reviewer,
      () => proposals.decide(
        note.id,
        proposal.id,
        {'decision': 'approve', 'record_revision': 1},
      ),
    );
    expect(accepted.acceptedVersion, 2);
    expect(await search.search('acceptedword'), isEmpty);
    expect(meta.get(note.id), isNull);
    expect((await storage.revisions(note.id)).last['deleted'], isTrue);
    expect(storage.historyNeedsReindex, isFalse);
  });

  test('failed index update keeps a ticket for startup rebuild', () async {
    final block = (await storage.readBlockMap(note.id)).blocks.single;
    final proposal = await withKnowledgePrincipal(
      proposer,
      () => proposals.submit(note.id, {
        'base_version': 1,
        'idempotency_key': 'fail',
        'operations': [
          {
            'type': 'replace',
            'block_id': block.id,
            'expected_revision': 1,
            'text': 'recoveredword',
          }
        ],
      }),
    );
    proposals = ProposalService(
      storage: storage,
      authorization: proposals.authorization,
      onAccepted: (note, actor, {required deleted}) async =>
          throw StateError('index failed'),
    );
    await expectLater(
      withKnowledgePrincipal(
        reviewer,
        () => proposals.decide(
          note.id,
          proposal.id,
          {'decision': 'approve', 'record_revision': 1},
        ),
      ),
      throwsStateError,
    );
    expect(
      (await storage.readProposalRecord(note.id, proposal.id)).state,
      'accepted',
    );
    expect(storage.historyNeedsReindex, isTrue);
    expect(await search.search('recoveredword'), isEmpty);
    search.close();
    storage = Storage(contentDir: Directory('${dir.path}/content'));
    search = await SearchIndex.open(
      dbFile: File('${dir.path}/search.db'),
      storage: storage,
    );
    expect((await search.search('recoveredword')).single.id, note.id);
    expect(await search.search('acceptedword'), isEmpty);
    expect(storage.historyNeedsReindex, isFalse);
  });
  test('reviewed definition retains its database index classification',
      () async {
    final definition = await storage.create(
      title: 'Definition',
      content: 'definitionbody',
      properties: {
        'type': 'database',
        'source': {'folder': ''},
        'properties': <String, Object?>{},
        'views': <Object?>[],
        'history': true,
      },
    );
    await writer.indexAcceptedProposal(definition, 'setup', deleted: false);
    await storage.acknowledgeIndexedRevision(definition.id, 1);
    final block = (await storage.readBlockMap(definition.id)).blocks.single;
    final proposal = await withKnowledgePrincipal(
      proposer,
      () => proposals.submit(definition.id, {
        'base_version': 1,
        'idempotency_key': 'definition',
        'operations': [
          {
            'type': 'replace',
            'block_id': block.id,
            'expected_revision': 1,
            'text': 'definitionsecret',
          }
        ],
      }),
    );
    await withKnowledgePrincipal(
      reviewer,
      () => proposals.decide(
        definition.id,
        proposal.id,
        {'decision': 'approve', 'record_revision': 1},
      ),
    );
    expect((await search.search('definitionsecret')).single.id, definition.id);
    expect(
      search.definitionsSource().any((row) => row.id == definition.id),
      isTrue,
    );
    expect((await storage.read(definition.id)).content, 'definitionsecret');
  });
}
