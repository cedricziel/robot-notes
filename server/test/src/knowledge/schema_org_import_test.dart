import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:server/src/knowledge/schema_org_import.dart';
import 'package:server/src/knowledge/type_review.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:test/test.dart';

List<int> artifact() => utf8.encode(
      jsonEncode({
        '@context': {
          'schema': 'https://schema.org/',
          'rdfs': 'http://www.w3.org/2000/01/rdf-schema#',
          'rdf': 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
        },
        '@graph': [
          {'@id': 'schema:Thing', '@type': 'rdfs:Class'},
          for (final name in [
            'Person',
            'Project',
            'Claim',
            'Action',
            'HowTo',
            'CreativeWork',
          ])
            {
              '@id': 'schema:$name',
              '@type': 'rdfs:Class',
              'rdfs:subClassOf': {'@id': 'schema:Thing'},
              'rdfs:comment': 'Fixture guidance',
            },
          {
            '@id': 'schema:name',
            '@type': 'rdf:Property',
            'schema:domainIncludes': {'@id': 'schema:Thing'},
          },
        ],
      }),
    );

void main() {
  final source = Uri.parse(
    'https://raw.githubusercontent.com/schemaorg/schemaorg/main/data/releases/30.1/schemaorg-all-https.jsonld',
  );
  test('preview pins terms and reports unsupported semantics', () {
    final preview = SchemaOrgImporter(
      trustedDigests: {'30.1': sha256.convert(artifact()).toString()},
    ).preview(artifact(), release: '30.1', source: source);
    expect(preview.identities, contains('https://schema.org/Person'));
    expect(
      preview.unsupported,
      contains('https://schema.org/name|schema:domainIncludes'),
    );
    expect(preview.digest, hasLength(64));
    expect(
      () => SchemaOrgImporter(
        trustedDigests: {'30.1': sha256.convert(artifact()).toString()},
      ).preview(
        artifact(),
        release: '30.1',
        source: Uri.parse('https://schema.org/version/latest/'),
      ),
      throwsFormatException,
    );
    expect(
      () => SchemaOrgImporter(
        trustedDigests: {'30.1': sha256.convert(artifact()).toString()},
      ).preview(
        artifact(),
        release: '30.1',
        source: source,
        expectedDigest: 'wrong',
      ),
      throwsFormatException,
    );
  });

  test('bulk adoption retains terms and constraints across retries', () async {
    final directory = await Directory.systemTemp.createTemp('schema-adoption-');
    try {
      await withKnowledgePrincipal(const KnowledgePrincipal.operator(),
          () async {
        final snapshots = KnowledgeTypeSnapshots(
          directory: directory,
          authorization:
              NoteAuthorizationService(store: KnowledgePolicyStore.memory()),
        );
        final review = KnowledgeTypeReview(snapshots: snapshots);
        final importer = SchemaOrgImporter(
          trustedDigests: {'30.1': sha256.convert(artifact()).toString()},
        );
        final preview =
            importer.preview(artifact(), release: '30.1', source: source);
        final dispositions = {
          for (final key in preview.unsupported.keys)
            key: 'preserve_as_guidance',
        };
        final proposal = await importer.propose(
          preview,
          review,
          unsupportedDispositions: dispositions,
        );
        expect(await snapshots.definitions(), isEmpty);
        await review.accept(proposal.id, expectedRecordRevision: 1);
        final definitions = await snapshots.definitions();
        expect(definitions, hasLength(13));
        expect(
          definitions
              .singleWhere(
            (definition) => definition.id == 'urn:robot-notes:type:Claim',
          )
              .validateProperties({}),
          isNotEmpty,
        );
        final retry = await importer.propose(
          preview,
          review,
          unsupportedDispositions: dispositions,
        );
        expect(retry.id, proposal.id);
        expect(retry.state, 'accepted');
        expect(await snapshots.definitions(), hasLength(13));
        expect(await snapshots.export(), hasLength(15));
        final bundle = await snapshots.exportBundle();
        expect(bundle['artifacts/${preview.digest}.bin'], artifact());
        expect(bundle['accepted.json'], isNotNull);
      });
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
