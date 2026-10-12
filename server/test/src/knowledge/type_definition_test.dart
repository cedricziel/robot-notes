import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:test/test.dart';

Map<String, Object?> definition(
  String id, {
  List<Object?> parents = const [],
  Map<String, Object?> properties = const {},
}) =>
    {
      'format_version': 1,
      'role': 'type_definition',
      'definition': {
        'id': id,
        'version': 1,
        'extends': parents,
        'properties': properties,
        'relations': <String, Object?>{},
        'guidance': {
          'sections': ['Statement'],
          'agent_instructions': 'Cite evidence.',
        },
      },
    };

void main() {
  test('type metadata round trip preserves database discriminator', () {
    final original = definition(
      'urn:test:Claim',
      properties: {
        'statement': {'value_type': 'text', 'required': true},
      },
    );
    final markdown = serializeFrontmatter(
      Frontmatter(
        metadata: {
          'type': 'database',
          'knowledge': original,
        },
        body: 'Guidance\n',
      ),
    );
    final decoded = KnowledgeTypeDefinition.fromMetadata(
      parseFrontmatter(markdown).metadata['knowledge'],
    );
    expect(decoded.toMetadata(), original);
    expect(parseFrontmatter(markdown).metadata['type'], 'database');
  });

  test('vocabulary identities and multiline guidance survive serialization',
      () {
    const metadata = <String, Object?>{
      'guidance': {
        '@id': 'schema:Claim',
        'rdfs:comment': 'First line\nSecond line\tquoted "value"',
      },
      'true': 'string key',
      'empty': <Object?>[
        <String, Object?>{},
        <Object?>[],
        {'items': <Object?>[]},
      ],
    };
    expect(
      parseFrontmatter(
        serializeFrontmatter(
          const Frontmatter(metadata: metadata, body: ''),
        ),
      ).metadata,
      metadata,
    );
  });

  test('unsupported format and malformed constraints fail closed', () {
    expect(
      () => KnowledgeTypeDefinition.fromMetadata(
        {...definition('urn:test:Claim'), 'format_version': 2},
      ),
      throwsFormatException,
    );
    expect(
      () => KnowledgeTypeDefinition.fromMetadata(
        definition(
          'urn:test:Claim',
          properties: {
            'x': {'value_type': 'magic'},
          },
        ),
      ),
      throwsFormatException,
    );
  });

  test('pinned parents preserve required properties and enforce narrowing', () {
    final parent = KnowledgeTypeDefinition.fromMetadata(
      definition(
        'urn:test:Parent',
        properties: {
          'status': {
            'value_type': 'text',
            'required': true,
            'enum': ['open', 'closed'],
          },
        },
      ),
    );
    final child = KnowledgeTypeDefinition.fromMetadata(
      definition(
        'urn:test:Child',
        parents: [
          {'id': parent.id, 'version': 1},
        ],
        properties: {
          'status': {
            'value_type': 'text',
            'required': true,
            'enum': ['closed'],
          },
        },
      ),
    );
    final resolved =
        KnowledgeTypeResolver([parent, child]).resolve(child.reference);
    expect(resolved.validateProperties({'status': 'open'}), isNotEmpty);
    expect(resolved.validateProperties({'status': 'closed'}), isEmpty);
    expect(resolved.validateProperties({}), isNotEmpty);
  });

  test('cycles and weaker inherited constraints cannot activate', () {
    final first = KnowledgeTypeDefinition.fromMetadata(
      definition(
        'urn:test:A',
        parents: [
          {'id': 'urn:test:B', 'version': 1},
        ],
      ),
    );
    final second = KnowledgeTypeDefinition.fromMetadata(
      definition(
        'urn:test:B',
        parents: [
          {'id': 'urn:test:A', 'version': 1},
        ],
      ),
    );
    expect(
      () => KnowledgeTypeResolver([first, second]).resolve(first.reference),
      throwsFormatException,
    );
    final parent = KnowledgeTypeDefinition.fromMetadata(
      definition(
        'urn:test:P',
        properties: {
          'name': {'value_type': 'text', 'required': true},
        },
      ),
    );
    final child = KnowledgeTypeDefinition.fromMetadata(
      definition(
        'urn:test:C',
        parents: [
          {'id': parent.id, 'version': 1},
        ],
        properties: {
          'name': {'value_type': 'text', 'required': false},
        },
      ),
    );
    expect(
      () => KnowledgeTypeResolver([parent, child]).resolve(child.reference),
      throwsFormatException,
    );
  });
}
