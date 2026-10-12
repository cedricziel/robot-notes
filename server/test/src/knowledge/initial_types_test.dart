import 'package:server/src/knowledge/initial_types.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:test/test.dart';

void main() {
  final parents = {
    for (final name in [
      'Person',
      'Project',
      'Claim',
      'Decision',
      'Procedure',
      'Evidence',
    ])
      name: KnowledgeTypeReference('urn:fixture:$name', 'release-1'),
  };
  final definitions = initialKnowledgeTypes(parents);
  final fixtures = parents.values.map(
    (parent) => KnowledgeTypeDefinition.fromMetadata({
      'format_version': 1,
      'role': 'type_definition',
      'definition': {
        ...parent.toJson(),
        'properties': <String, Object?>{},
        'relations': <String, Object?>{},
      },
    }),
  );
  final resolver = KnowledgeTypeResolver([...fixtures, ...definitions]);
  KnowledgeTypeReference type(String name) =>
      KnowledgeTypeReference('urn:robot-notes:type:$name', 1);

  test('Person and Project require nonempty descriptive properties', () {
    expect(
      resolver
          .resolve(type('Person'))
          .validateProperties({'display_name': ' '}),
      isNotEmpty,
    );
    expect(
      resolver
          .resolve(type('Person'))
          .validateProperties({'display_name': 'Ada'}),
      isEmpty,
    );
    expect(
      resolver.resolve(type('Project')).validateProperties({}),
      isNotEmpty,
    );
    expect(
      resolver
          .resolve(type('Project'))
          .validateProperties({'summary': 'Shared knowledge'}),
      isEmpty,
    );
  });
  test('Claim needs a statement and an Evidence target', () {
    expect(resolver.resolve(type('Claim')).validateProperties({}), isNotEmpty);
    expect(resolver.validateRelations(type('Claim'), {}, {}), isNotEmpty);
    expect(
      resolver.validateRelations(type('Claim'), {
        'supported_by': ['e'],
      }, {
        'e': [type('Evidence')],
      }),
      isEmpty,
    );
    expect(
      resolver.validateRelations(type('Claim'), {
        'supported_by': ['p'],
      }, {
        'p': [type('Person')],
      }),
      isNotEmpty,
    );
  });
  test('Decision validates date, status, and Project relation', () {
    final decision = resolver.resolve(type('Decision'));
    expect(
      decision.validateProperties({
        'rationale': 'Keep evidence',
        'decision_date': '2026-02-30',
        'status': 'accepted',
      }),
      isNotEmpty,
    );
    expect(
      decision.validateProperties({
        'rationale': 'Keep evidence',
        'decision_date': '2026-10-12',
        'status': 'accepted',
      }),
      isEmpty,
    );
    expect(
      resolver.validateRelations(type('Decision'), {
        'affects': ['p'],
      }, {
        'p': [type('Project')],
      }),
      isEmpty,
    );
  });
  test('Procedure needs nonempty ordered steps and a Person maintainer', () {
    final procedure = resolver.resolve(type('Procedure'));
    expect(procedure.validateProperties({'steps': <String>[]}), isNotEmpty);
    expect(
      procedure.validateProperties({
        'steps': [''],
      }),
      isNotEmpty,
    );
    expect(
      procedure.validateProperties({
        'steps': ['Read', 'Compare'],
      }),
      isEmpty,
    );
    expect(
      resolver.validateRelations(type('Procedure'), {
        'maintained_by': ['p'],
      }, {
        'p': [type('Person')],
      }),
      isEmpty,
    );
  });
  test('Evidence uses structured sources instead of editable properties', () {
    final evidence = resolver.resolve(type('Evidence'));
    expect(evidence.properties, isEmpty);
    expect(
      (evidence.toMetadata()['definition']!
          as Map<String, Object?>)['guidance'],
      isNotNull,
    );
  });
}
