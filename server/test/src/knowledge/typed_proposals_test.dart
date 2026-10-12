import 'dart:io';

import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/source_store.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge/typed_proposals.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import 'type_definition_test.dart' show definition;

void main() {
  late Directory directory;
  late Storage storage;
  late KnowledgeTypeSnapshots types;
  late KnowledgeSourceStore sources;
  late TypedKnowledgeProposals proposals;
  late NoteAuthorizationService authorization;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('typed-group-');
    authorization =
        NoteAuthorizationService(store: KnowledgePolicyStore.memory());
    storage = Storage(contentDir: Directory('${directory.path}/notes'));
    types = KnowledgeTypeSnapshots(
      directory: Directory('${directory.path}/types'),
      authorization: authorization,
    );
    sources = KnowledgeSourceStore(
      directory: Directory('${directory.path}/sources'),
      authorization: authorization,
    );
    proposals = TypedKnowledgeProposals(
      storage: storage,
      types: types,
      sources: sources,
      authorization: authorization,
      onAccepted: (_) async {},
    );
    await withKnowledgePrincipal(
      const KnowledgePrincipal.operator(),
      () => types.accept(
        {
          'person.md': serializeFrontmatter(
            Frontmatter(
              metadata: {
                'knowledge': definition(
                  'urn:test:Person',
                  properties: {
                    'name': {'value_type': 'text', 'required': true},
                  },
                ),
              },
              body: '',
            ),
          ),
        },
        expectedGeneration: 0,
      ),
    );
  });
  tearDown(() async {
    sources.close();
    await directory.delete(recursive: true);
  });
  final operations = <Object?>[
    {
      'kind': 'create',
      'local_ref': 'a',
      'title': 'Ada',
      'properties': {'name': 'Ada'},
      'types': [
        {'id': 'urn:test:Person', 'version': 1},
      ],
    },
    {
      'kind': 'create',
      'local_ref': 'b',
      'title': 'Grace',
      'properties': {'name': 'Grace'},
      'types': [
        {'id': 'urn:test:Person', 'version': 1},
      ],
    },
  ];
  test('pending groups reserve IDs without accepted placeholders', () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final draft =
          await proposals.propose(operations, idempotencyKey: 'group-1');
      expect(await storage.list(), isEmpty);
      final retry =
          await proposals.propose(operations, idempotencyKey: 'group-1');
      expect(retry.id, draft.id);
      final accepted = await proposals.accept(
        draft.noteId,
        draft.id,
        expectedRecordRevision: 1,
      );
      expect(accepted.state, 'accepted');
      expect(await storage.list(), hasLength(2));
      expect(
        (await proposals.inspect(draft.noteId, draft.id)).state,
        'accepted',
      );
    });
  });
  test('incomplete candidate stays inspectable and cannot publish', () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final incomplete = <Object?>[
        {
          'kind': 'create',
          'local_ref': 'x',
          'title': 'Unknown',
          'types': [
            {'id': 'urn:test:Person', 'version': 1},
          ],
        }
      ];
      final draft =
          await proposals.propose(incomplete, idempotencyKey: 'incomplete');
      expect(draft.versions.last.candidate['diagnostics'], isNotEmpty);
      await expectLater(
        proposals.accept(draft.noteId, draft.id, expectedRecordRevision: 1),
        throwsA(isA<Exception>()),
      );
      expect(await storage.list(), isEmpty);
    });
  });
  test('amendment retains candidate history and rejects stale approval',
      () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final draft =
          await proposals.propose(operations, idempotencyKey: 'amend');
      final amended = await proposals.amend(
        draft.noteId,
        draft.id,
        operations,
        idempotencyKey: 'amend-1',
        expectedRecordRevision: 1,
        expectedProposalRevision: 1,
      );
      expect(amended.versions, hasLength(2));
      expect(
        amended.versions.last.candidate['reserved'],
        draft.versions.first.candidate['reserved'],
      );
      await expectLater(
        proposals.accept(draft.noteId, draft.id, expectedRecordRevision: 1),
        throwsA(isA<Exception>()),
      );
      expect(await storage.list(), isEmpty);
    });
  });

  test('interrupted group publication blocks reads until restart replay',
      () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final failing = Storage(
        contentDir: storage.contentDir,
        afterHistoryPublish: () async => throw StateError('injected failure'),
      );
      final service = TypedKnowledgeProposals(
        storage: failing,
        types: types,
        sources: sources,
        authorization: authorization,
        onAccepted: (_) async {},
      );
      final draft = await service.propose(operations, idempotencyKey: 'crash');
      await expectLater(
        service.accept(draft.noteId, draft.id, expectedRecordRevision: 1),
        throwsStateError,
      );
      await expectLater(failing.list(), throwsStateError);
      final restored = Storage(
        contentDir: storage.contentDir,
        acceptedPolicyReplay: authorization.store.replayAcceptedNoteDesignation,
      );
      expect(await restored.list(), hasLength(2));
      expect(
        (await restored.readProposalRecord(draft.noteId, draft.id)).state,
        'accepted',
      );
    });
  });

  test('derived index failure cannot undo a committed human decision',
      () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final service = TypedKnowledgeProposals(
        storage: storage,
        types: types,
        sources: sources,
        authorization: authorization,
        onAccepted: (_) async => throw StateError('index unavailable'),
      );
      final draft = await service.propose(operations, idempotencyKey: 'index');
      final accepted = await service.accept(
        draft.noteId,
        draft.id,
        expectedRecordRevision: 1,
      );
      expect(accepted.state, 'accepted');
      expect(await storage.list(), hasLength(2));
      expect(storage.historyNeedsReindex, isTrue);
    });
  });

  test('proposal history retains original path authorization after a move',
      () async {
    late String noteId;
    late String proposalId;
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final first = await proposals.propose(operations, idempotencyKey: 'base');
      await proposals.accept(first.noteId, first.id, expectedRecordRevision: 1);
      final note = await storage.read((await storage.list()).first.id);
      noteId = note.id;
      final pending = await proposals.propose(
        [
          {
            'kind': 'update',
            'id': note.id,
            'expected_revision': note.version,
            'properties': {'name': 'Updated name'},
          },
        ],
        idempotencyKey: 'update',
      );
      proposalId = pending.id;
      await storage.update(
        id: note.id,
        title: note.title,
        content: note.content,
        ifMatch: note.version,
        path: 'public',
      );
      await authorization.putFolderPolicy(
        const KnowledgePrincipal.operator(),
        'knowledge',
        KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
      );
    });
    await expectLater(
      withKnowledgePrincipal(
        KnowledgePrincipal.agent(
          credentialId: 'reader',
          scopes: {'notes:read', 'knowledge:propose'},
        ),
        () => proposals.inspect(noteId, proposalId),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
  });
}
