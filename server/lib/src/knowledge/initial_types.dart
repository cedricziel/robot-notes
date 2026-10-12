import 'package:server/src/knowledge/type_definition.dart';

/// Builds local definitions against explicitly pinned imported parents.
/// The caller must resolve and review every parent before activating the group.
List<KnowledgeTypeDefinition> initialKnowledgeTypes(
  Map<String, KnowledgeTypeReference> importedParents,
) {
  const namespace = 'urn:robot-notes:type:';
  Map<String, Object?> relation(String name, {int minimum = 0}) => {
        'target_types': [
          {'id': '$namespace$name', 'version': 1},
        ],
        'min_items': minimum,
      };
  Map<String, Object?> text() => {'value_type': 'text', 'required': true};
  final constraints = <String, Map<String, Object?>>{
    'Person': {
      'properties': {'display_name': text()},
      'relations': <String, Object?>{},
    },
    'Project': {
      'properties': {'summary': text()},
      'relations': {'maintained_by': relation('Person')},
    },
    'Claim': {
      'properties': {'statement': text()},
      'relations': {'supported_by': relation('Evidence', minimum: 1)},
    },
    'Decision': {
      'properties': {
        'rationale': text(),
        'decision_date': {'value_type': 'date', 'required': true},
        'status': {
          'value_type': 'text',
          'required': true,
          'enum': ['proposed', 'accepted', 'superseded'],
        },
      },
      'relations': {
        'affects': relation('Project', minimum: 1),
        'supported_by': relation('Evidence'),
        'supersedes': relation('Decision'),
      },
    },
    'Procedure': {
      'properties': {
        'steps': {
          'value_type': 'list',
          'required': true,
          'min_items': 1,
          'items': {'value_type': 'text', 'required': true},
        },
      },
      'relations': {
        'maintained_by': relation('Person', minimum: 1),
        'supported_by': relation('Evidence'),
      },
    },
    'Evidence': {
      'properties': <String, Object?>{},
      'relations': <String, Object?>{},
    },
  };
  return constraints.entries.map((entry) {
    final parent = importedParents[entry.key];
    if (parent == null) {
      throw FormatException('Missing imported parent for ${entry.key}');
    }
    return KnowledgeTypeDefinition.fromMetadata({
      'format_version': 1,
      'role': 'type_definition',
      'definition': {
        'id': '$namespace${entry.key}',
        'version': 1,
        'extends': [parent.toJson()],
        ...entry.value,
        'guidance': {
          'sections': entry.key == 'Evidence'
              ? ['Source', 'Locator']
              : (entry.value['properties']! as Map<String, Object?>)
                  .keys
                  .toList(),
          'agent_instructions': entry.key == 'Evidence'
              ? 'Reference an immutable source revision and '
                  'exact passage or whole-document locator.'
              : 'Read sources, compare knowledge, classify findings, '
                  'and propose a focused change for human review.',
        },
      },
    });
  }).toList();
}
