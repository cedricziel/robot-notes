import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/initial_types.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:server/src/knowledge/type_review.dart';
import 'package:server/src/proposals/proposal_record.dart';

/// A pinned release preview; nothing becomes accepted during decoding.
class SchemaOrgPreview {
  SchemaOrgPreview._(
    this.release,
    this.source,
    this.digest,
    this.bytes,
    this.terms,
    this.context,
  );

  /// Published release identifier.
  final String release;

  /// Versioned artifact URL, never latest or a development endpoint.
  final Uri source;

  /// Immutable original-byte digest.
  final String digest;

  /// Original JSON-LD bytes retained on proposal submission.
  final List<int> bytes;

  /// Original vocabulary nodes, without losing unsupported predicates.
  final List<Map<String, dynamic>> terms;

  /// Prefix expansion from the pinned release artifact.
  final Map<String, dynamic> context;

  String _expand(String value) {
    if (value.startsWith('https://') || value.startsWith('http://')) {
      return value;
    }
    final colon = value.indexOf(':');
    final prefix = colon < 0 ? null : context[value.substring(0, colon)];
    if (prefix is! String) {
      throw FormatException('Unresolved vocabulary prefix: $value');
    }
    return '$prefix${value.substring(colon + 1)}';
  }

  List<String> _ids(Object? value) {
    final items = value is List<Object?> ? value : [if (value != null) value];
    return items.map((item) {
      if (item is String) return _expand(item);
      if (item is Map<String, dynamic> && item['@id'] is String) {
        return _expand(item['@id'] as String);
      }
      throw const FormatException('Unsupported vocabulary identity');
    }).toList();
  }

  /// Every semantic construct not enforced as a pinned subclass relationship.
  Map<String, Object?> get unsupported {
    final known = terms.map((term) => _expand(term['@id'] as String)).toSet();
    final result = <String, Object?>{};
    for (final term in terms) {
      final id = _expand(term['@id'] as String);
      for (final entry in term.entries) {
        if (const {
          '@id',
          '@type',
          'rdfs:label',
          'rdfs:comment',
          'rdfs:subClassOf',
        }.contains(entry.key)) {
          continue;
        }
        result['$id|${entry.key}'] = entry.value;
      }
      for (final parent in _ids(term['rdfs:subClassOf'])) {
        if (!known.contains(parent)) result['$id|parent:$parent'] = parent;
      }
    }
    return result;
  }

  /// Stable original term identities for collision and dependency previews.
  List<String> get identities =>
      terms.map((term) => _expand(term['@id'] as String)).toList();

  Map<String, String> _documents(
    Map<String, String> dispositions, {
    required bool includeLocalTypes,
  }) {
    if (dispositions.keys
            .toSet()
            .difference(unsupported.keys.toSet())
            .isNotEmpty ||
        unsupported.keys
            .any((key) => dispositions[key] != 'preserve_as_guidance')) {
      throw const FormatException('Explicit unsupported dispositions required');
    }
    final adoptionId = 'urn:robot-notes:adoption:schema.org:$release:$digest';
    final known = identities.toSet();
    final documents = <String, String>{};
    final references = <Map<String, Object?>>[];
    for (final term in terms) {
      final id = _expand(term['@id'] as String);
      final name = Uri.parse(id).pathSegments.last;
      final classes = _ids(term['@type']);
      final isClass =
          classes.contains('http://www.w3.org/2000/01/rdf-schema#Class');
      final origin = {'adoption_id': adoptionId, 'term_uri': id};
      final metadata = isClass
          ? <String, Object?>{
              'format_version': 1,
              'role': 'type_definition',
              'definition': {
                'id': id,
                'version': release,
                'extends': [
                  for (final parent in _ids(term['rdfs:subClassOf']))
                    if (known.contains(parent))
                      {'id': parent, 'version': release},
                ],
                'properties': <String, Object?>{},
                'relations': <String, Object?>{},
                'origin': origin,
                'guidance': {'original_definition': term},
              },
            }
          : <String, Object?>{
              'format_version': 1,
              'role': 'vocabulary_term',
              'term': {
                'id': id,
                'version': release,
                'kind': classes.contains(
                  'http://www.w3.org/1999/02/22-rdf-syntax-ns#Property',
                )
                    ? 'property'
                    : 'individual',
                'origin': origin,
                'definition': term,
              },
            };
      final slug = sha256.convert(utf8.encode(id)).toString();
      documents['schema.org/$release/$slug.md'] = serializeFrontmatter(
        Frontmatter(
          metadata: {'title': name, 'knowledge': metadata},
          body: '${term['rdfs:comment'] ?? ''}\n',
        ),
      );
      references.add({'id': id, 'version': release});
    }
    final mappings = {
      'Person': 'Person',
      'Project': 'Project',
      'Claim': 'Claim',
      'Decision': 'Action',
      'Procedure': 'HowTo',
      'Evidence': 'CreativeWork',
    };
    final locals = initialKnowledgeTypes({
      for (final entry in mappings.entries)
        entry.key: KnowledgeTypeReference(
          'https://schema.org/${entry.value}',
          release,
        ),
    });
    for (final definition in locals) {
      final name = definition.id.split(':').last;
      if (includeLocalTypes) {
        documents['local/$release/$name.md'] = serializeFrontmatter(
          Frontmatter(
            metadata: {'title': name, 'knowledge': definition.toMetadata()},
            body: 'Local knowledge constraints.\n',
          ),
        );
      }
      references.add(definition.reference.toJson());
    }
    documents['adoptions/$digest.md'] = serializeFrontmatter(
      Frontmatter(
        metadata: {
          'title': 'Schema.org $release adoption',
          'knowledge': {
            'format_version': 1,
            'role': 'ontology_adoption',
            'adoption': {
              'id': adoptionId,
              'namespace': 'https://schema.org/',
              'release': release,
              'artifact_source': source.toString(),
              'sha256': digest,
              'definitions': references,
              'dependencies': const <Object?>[],
              'unsupported_dispositions': dispositions,
            },
          },
        },
        body: 'Review unsupported semantics before activation.\n',
      ),
    );
    return documents;
  }
}

/// JSON-LD importer bound to explicit published release artifacts and human
/// review.
class SchemaOrgImporter {
  /// Accepts only explicitly cataloged published artifact digests.
  /// Fixtures can inject their own catalog without weakening production checks.
  SchemaOrgImporter({Map<String, String>? trustedDigests})
      : _trustedDigests = trustedDigests ??
            const {
              '30.1': '07e7c663dbc12a0937581745e59a98ed12'
                  'b8698f38e8e3b03650287d9df88ae5',
            };
  final Map<String, String> _trustedDigests;

  /// Decodes original bytes with an optional externally pinned expected digest.
  SchemaOrgPreview preview(
    List<int> bytes, {
    required String release,
    required Uri source,
    String? expectedDigest,
  }) {
    if (!RegExp(r'^\d+\.\d+$').hasMatch(release) ||
        source.host != 'raw.githubusercontent.com' ||
        !source.path.startsWith('/schemaorg/schemaorg/') ||
        !source.path.endsWith('/schemaorg-all-https.jsonld') ||
        source.scheme != 'https' ||
        !source.path.contains('/releases/$release/') ||
        source.path.contains('/latest/') ||
        source.path.contains('/dev/')) {
      throw const FormatException('Published versioned artifact required');
    }
    final digest = sha256.convert(bytes).toString();
    if (_trustedDigests[release] != digest ||
        (expectedDigest != null && digest != expectedDigest)) {
      throw const FormatException('Release digest mismatch');
    }
    final input = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final context = input['@context'] as Map<String, dynamic>;
    if (context['schema'] != 'https://schema.org/') {
      throw const FormatException('Unexpected Schema.org namespace');
    }
    final terms =
        (input['@graph'] as List<dynamic>).cast<Map<String, dynamic>>();
    final preview = SchemaOrgPreview._(
      release,
      source,
      digest,
      List.unmodifiable(bytes),
      terms,
      context,
    );
    if (preview.identities.toSet().length != terms.length) {
      throw const FormatException('Duplicate vocabulary identity');
    }
    return preview;
  }

  /// Submits the entire adoption through type review without activation
  /// authority.
  Future<ProposalRecord> propose(
    SchemaOrgPreview preview,
    KnowledgeTypeReview review, {
    required Map<String, String> unsupportedDispositions,
  }) async {
    await review.snapshots.retainArtifact(preview.bytes);
    final accepted = await review.snapshots.definitions();
    final locals = accepted
        .where(
          (definition) => definition.id.startsWith('urn:robot-notes:type:'),
        )
        .toList();
    return review.propose(
      preview._documents(
        unsupportedDispositions,
        includeLocalTypes: locals.isEmpty ||
            locals.every(
              (definition) => definition.parents
                  .every((parent) => parent.version == preview.release),
            ),
      ),
      idempotencyKey: 'schema-org:${preview.release}:${preview.digest}',
    );
  }
}
