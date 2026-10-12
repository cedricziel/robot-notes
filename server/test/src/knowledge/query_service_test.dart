import 'dart:io';

import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/query_service.dart';
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
  late KnowledgeSourceStore sources;
  late TypedKnowledgeProposals proposals;
  late KnowledgeQueryService queries;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('knowledge-query-');
    final authorization =
        NoteAuthorizationService(store: KnowledgePolicyStore.memory());
    storage = Storage(contentDir: Directory('${directory.path}/notes'));
    final types = KnowledgeTypeSnapshots(
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
    queries = KnowledgeQueryService(
      storage: storage,
      types: types,
      authorization: authorization,
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
  test('queries exclude pending groups and paginate accepted entries',
      () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final draft =
          await proposals.propose(operations, idempotencyKey: 'query');
      expect((await queries.query({}))['items'], isEmpty);
      await proposals.accept(draft.noteId, draft.id, expectedRecordRevision: 1);
      final first = await queries.query({
        'limit': 1,
        'sort': {'field': 'title', 'direction': 'asc'},
      });
      expect(
        (first['items']! as List<Object?>).single,
        containsPair('title', 'Ada'),
      );
      final next = await queries.query({
        'limit': 1,
        'sort': {'field': 'title', 'direction': 'asc'},
        'cursor': first['next_cursor'],
      });
      expect(
        (next['items']! as List<Object?>).single,
        containsPair('title', 'Grace'),
      );
    });
  });
  test('unsupported filter pairs fail even when no entries exist', () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      await expectLater(
        queries.query({
          'properties': [
            {'field': 'name', 'operator': 'gt', 'value': 3},
          ],
        }),
        throwsFormatException,
      );
      await expectLater(
        queries.query({
          'sort': {'field': 'undeclared'},
        }),
        throwsFormatException,
      );
    });
  });

  test('accepted query cursors become stale after publication', () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final draft = await proposals.propose(operations, idempotencyKey: 'old');
      await proposals.accept(draft.noteId, draft.id, expectedRecordRevision: 1);
      final page = await queries.query({'limit': 1});
      final more = await proposals.propose(
        <Object?>[
          {
            'kind': 'create',
            'local_ref': 'c',
            'title': 'Linus',
            'properties': {'name': 'Linus'},
            'types': [
              {'id': 'urn:test:Person', 'version': 1},
            ],
          }
        ],
        idempotencyKey: 'more',
      );
      await proposals.accept(more.noteId, more.id, expectedRecordRevision: 1);
      await expectLater(
        queries.query({'limit': 1, 'cursor': page['next_cursor']}),
        throwsA(isA<KnowledgeCursorStale>()),
      );
    });
  });

  test('unreviewed moves cannot expose a private accepted snapshot', () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final draft = await proposals.propose(operations, idempotencyKey: 'move');
      await proposals.accept(draft.noteId, draft.id, expectedRecordRevision: 1);
      final note = await storage.read((await storage.list()).first.id);
      final file = File(
        '${storage.contentDir.path}/${note.path}/${note.title}.md',
      );
      final accepted = parseFrontmatter(await file.readAsString());
      final destination = File(
        '${storage.contentDir.path}/public/${note.title}.md',
      );
      await destination.parent.create(recursive: true);
      await destination.writeAsString(
        serializeFrontmatter(
          Frontmatter(
            metadata: {...accepted.metadata, 'path': 'public'},
            body: accepted.body,
          ),
        ),
      );
      await file.delete();
      await queries.authorization.putFolderPolicy(
        const KnowledgePrincipal.operator(),
        'knowledge',
        KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
      );
    });
    await withKnowledgePrincipal(
      KnowledgePrincipal.agent(credentialId: 'reader', scopes: {'notes:read'}),
      () async {
        expect((await queries.query({}))['items'], isEmpty);
      },
    );
  });
}
