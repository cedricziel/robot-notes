import 'dart:convert';
import 'dart:io';

import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:test/test.dart';

import 'type_definition_test.dart' show definition;

void main() {
  late Directory directory;
  late KnowledgeTypeSnapshots snapshots;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('knowledge-types-');
    snapshots = KnowledgeTypeSnapshots(
      directory: directory,
      authorization:
          NoteAuthorizationService(store: KnowledgePolicyStore.memory()),
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  test('offline rebuild preserves accepted pins despite external edits',
      () async {
    final original = serializeFrontmatter(
      Frontmatter(
        metadata: {'knowledge': definition('urn:test:Claim')},
        body: 'Accepted guidance\n',
      ),
    );
    await withKnowledgePrincipal(
      const KnowledgePrincipal.operator(),
      () => snapshots.accept({'claim.md': original}, expectedGeneration: 0),
    );
    await File('${directory.path}/types/claim.md').writeAsString(
      original.replaceAll('Accepted guidance', 'Unreviewed guidance'),
    );
    final restored = KnowledgeTypeSnapshots(
      directory: directory,
      authorization: snapshots.authorization,
    );
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final definitions = await restored.definitions();
      expect(definitions.single.id, 'urn:test:Claim');
      expect(await restored.externalCandidates(), contains('claim.md'));
      final exported =
          parseFrontmatter((await restored.export()).values.single);
      expect(exported.body, 'Accepted guidance\n');
      expect(exported.metadata['knowledge'], definition('urn:test:Claim'));
      expect(exported.metadata['id'], isA<String>());
    });
  });

  test('restart completes interrupted group publication', () async {
    final original = serializeFrontmatter(
      Frontmatter(
        metadata: {
          'knowledge': definition('urn:test:Claim'),
        },
        body: 'Accepted guidance\n',
      ),
    );
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      await snapshots.accept({'claim.md': original}, expectedGeneration: 0);
      final published =
          await File('${directory.path}/types/claim.md').readAsString();
      await File('${directory.path}/types/claim.md').delete();
      await File('${directory.path}/publication.json').writeAsString(
        jsonEncode({
          'generation': 1,
          'documents': {'claim.md': published},
        }),
      );
      await snapshots.definitions();
      expect(
        await File('${directory.path}/types/claim.md').readAsString(),
        published,
      );
      expect(File('${directory.path}/publication.json').existsSync(), isFalse);
    });
  });

  test('agent review authority never activates type snapshots', () async {
    final markdown = serializeFrontmatter(
      Frontmatter(
        metadata: {'knowledge': definition('urn:test:Claim')},
        body: '',
      ),
    );
    final agent = KnowledgePrincipal.agent(
      credentialId: 'worker',
      scopes: {'notes:read', 'knowledge:propose', 'knowledge:review'},
    );
    await expectLater(
      withKnowledgePrincipal(
        agent,
        () => snapshots.accept({'claim.md': markdown}, expectedGeneration: 0),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    expect(File('${directory.path}/accepted.json').existsSync(), isFalse);
  });

  test('invalid inheritance leaves whole accepted group unchanged', () async {
    final markdown = serializeFrontmatter(
      Frontmatter(
        metadata: {
          'knowledge': definition(
            'urn:test:Child',
            parents: [
              {'id': 'urn:test:Missing', 'version': 1},
            ],
          ),
        },
        body: '',
      ),
    );
    await expectLater(
      withKnowledgePrincipal(
        const KnowledgePrincipal.operator(),
        () => snapshots.accept({'child.md': markdown}, expectedGeneration: 0),
      ),
      throwsFormatException,
    );
    expect(File('${directory.path}/accepted.json').existsSync(), isFalse);
  });
}
