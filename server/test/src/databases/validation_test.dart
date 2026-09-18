import 'package:server/src/databases/validation.dart';
import 'package:server/src/storage.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

DatabaseDefinition _def({
  String id = 'db1',
  String title = 'Projects',
  DatabaseSource? source,
  Map<String, PropertyDefinition> properties = const {},
  List<ViewDefinition> views = const [],
}) {
  return DatabaseDefinition(
    id: id,
    title: title,
    path: 'Projects',
    version: 1,
    source: source ?? DatabaseSource.folder('Projects'),
    properties: properties,
    views: views,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
}

NoteSummary _note({
  String id = 'n1',
  String title = 'Alice',
  String path = 'People',
  Set<String> tags = const {},
}) {
  return NoteSummary(
    id: id,
    title: title,
    path: path,
    version: 1,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    tags: tags,
  );
}

void main() {
  group('validateDefinition', () {
    test('valid definition has no violations', () {
      final def = _def(
        properties: {
          'status': const PropertyDefinition(
            type: PropertyType.select,
            options: ['Idea', 'Active', 'Done'],
          ),
        },
        views: [
          const ViewDefinition(name: 'All', type: ViewType.table),
          const ViewDefinition(
            name: 'Kanban',
            type: ViewType.board,
            groupBy: 'status',
          ),
        ],
      );
      expect(validateDefinition(def), isEmpty);
    });

    test('reserved property key is rejected', () {
      final def = _def(
        properties: {
          'version': const PropertyDefinition(type: PropertyType.text),
        },
      );
      final violations = validateDefinition(def);
      expect(violations, isNotEmpty);
      expect(violations.first.path, 'properties.version');
    });

    test('property key not matching the pattern is rejected', () {
      final def = _def(
        properties: {
          'Status': const PropertyDefinition(type: PropertyType.text),
        },
      );
      expect(validateDefinition(def), isNotEmpty);
    });

    test('select without options is rejected', () {
      final def = _def(
        properties: {
          'status': const PropertyDefinition(type: PropertyType.select),
        },
      );
      final violations = validateDefinition(def);
      expect(
          violations.map((v) => v.path), contains('properties.status.options'));
    });

    test('select with duplicate options is rejected', () {
      final def = _def(
        properties: {
          'status': const PropertyDefinition(
            type: PropertyType.select,
            options: ['Idea', 'Idea'],
          ),
        },
      );
      final violations = validateDefinition(def);
      expect(violations, isNotEmpty);
    });

    test(
        'unknown type cannot occur post-parse but multi_select without options is rejected',
        () {
      final def = _def(
        properties: {
          'labels': const PropertyDefinition(type: PropertyType.multiSelect),
        },
      );
      expect(validateDefinition(def), isNotEmpty);
    });

    test('duplicate view names case-insensitive are rejected', () {
      final def = _def(
        views: const [
          ViewDefinition(name: 'All', type: ViewType.table),
          ViewDefinition(name: 'all', type: ViewType.list),
        ],
      );
      final violations = validateDefinition(def);
      expect(violations, isNotEmpty);
    });

    test('board without group_by is rejected', () {
      final def = _def(
        views: const [ViewDefinition(name: 'Kanban', type: ViewType.board)],
      );
      final violations = validateDefinition(def);
      expect(violations.map((v) => v.path), contains('views[0].group_by'));
    });

    test('board group_by not a select property is rejected', () {
      final def = _def(
        properties: {
          'status': const PropertyDefinition(type: PropertyType.text),
        },
        views: const [
          ViewDefinition(
              name: 'Kanban', type: ViewType.board, groupBy: 'status'),
        ],
      );
      final violations = validateDefinition(def);
      expect(violations.map((v) => v.path), contains('views[0].group_by'));
    });

    test('filter referencing an undeclared property is rejected', () {
      final def = _def(
        views: const [
          ViewDefinition(
            name: 'All',
            type: ViewType.table,
            filter: Condition(property: 'nope', op: FilterOp.eq, value: 'x'),
          ),
        ],
      );
      final violations = validateDefinition(def);
      expect(
          violations.map((v) => v.path), contains('views[0].filter.property'));
    });

    test('filter with an inapplicable operator is rejected', () {
      final def = _def(
        properties: {
          'done': const PropertyDefinition(type: PropertyType.checkbox),
        },
        views: const [
          ViewDefinition(
            name: 'All',
            type: ViewType.table,
            filter: Condition(property: 'done', op: FilterOp.gt, value: 1),
          ),
        ],
      );
      final violations = validateDefinition(def);
      expect(violations.map((v) => v.path), contains('views[0].filter.op'));
    });

    test('is_empty with a value is rejected', () {
      final def = _def(
        properties: {
          'status': const PropertyDefinition(
            type: PropertyType.select,
            options: ['Idea'],
          ),
        },
        views: const [
          ViewDefinition(
            name: 'All',
            type: ViewType.table,
            filter: Condition(
                property: 'status', op: FilterOp.isEmpty, value: 'Idea'),
          ),
        ],
      );
      final violations = validateDefinition(def);
      expect(violations.map((v) => v.path), contains('views[0].filter.value'));
    });

    test('a filter on a built-in field is accepted', () {
      final def = _def(
        views: const [
          ViewDefinition(
            name: 'Recent',
            type: ViewType.table,
            filter: Condition(
                property: 'updated_at', op: FilterOp.gte, value: '2026-01-01'),
          ),
        ],
      );
      expect(validateDefinition(def), isEmpty);
    });

    test('nested and/or filters are validated recursively', () {
      final def = _def(
        properties: {
          'status': const PropertyDefinition(
              type: PropertyType.select, options: ['Idea']),
        },
        views: const [
          ViewDefinition(
            name: 'All',
            type: ViewType.table,
            filter: Or([
              Condition(property: 'status', op: FilterOp.eq, value: 'Idea'),
              Condition(property: 'nope', op: FilterOp.eq, value: 'x'),
            ]),
          ),
        ],
      );
      final violations = validateDefinition(def);
      expect(violations.map((v) => v.path),
          contains('views[0].filter.or[1].property'));
    });
  });

  group('validateProperties', () {
    test('text accepted, wrong type rejected', () {
      final covering = [
        _def(properties: {
          'summary': const PropertyDefinition(type: PropertyType.text)
        }),
      ];
      expect(validateProperties(covering, {'summary': 'hello'}), isEmpty);
      expect(validateProperties(covering, {'summary': 5}), isNotEmpty);
    });

    test('number rejects a string form', () {
      final covering = [
        _def(properties: {
          'budget': const PropertyDefinition(type: PropertyType.number)
        }),
      ];
      expect(validateProperties(covering, {'budget': 12}), isEmpty);
      expect(validateProperties(covering, {'budget': 12.5}), isEmpty);
      expect(validateProperties(covering, {'budget': '12'}), isNotEmpty);
    });

    test('checkbox requires a bool', () {
      final covering = [
        _def(properties: {
          'done': const PropertyDefinition(type: PropertyType.checkbox)
        }),
      ];
      expect(validateProperties(covering, {'done': true}), isEmpty);
      expect(validateProperties(covering, {'done': 'yes'}), isNotEmpty);
    });

    test('date accepts a day or a timestamp', () {
      final covering = [
        _def(properties: {
          'due': const PropertyDefinition(type: PropertyType.date)
        }),
      ];
      expect(validateProperties(covering, {'due': '2026-10-01'}), isEmpty);
      expect(validateProperties(covering, {'due': '2026-10-01T09:00:00Z'}),
          isEmpty);
      expect(validateProperties(covering, {'due': 'not-a-date'}), isNotEmpty);
    });

    test('select must be a declared option', () {
      final covering = [
        _def(
          properties: {
            'status': const PropertyDefinition(
                type: PropertyType.select, options: ['Idea', 'Active', 'Done']),
          },
        ),
      ];
      expect(validateProperties(covering, {'status': 'Active'}), isEmpty);
      expect(validateProperties(covering, {'status': 'Blocked'}), isNotEmpty);
    });

    test('multi_select must be a list of declared options', () {
      final covering = [
        _def(
          properties: {
            'labels': const PropertyDefinition(
                type: PropertyType.multiSelect, options: ['Urgent', 'Blocked']),
          },
        ),
      ];
      expect(
          validateProperties(covering, {
            'labels': ['Urgent']
          }),
          isEmpty);
      expect(
          validateProperties(covering, {
            'labels': ['Nope']
          }),
          isNotEmpty);
      expect(validateProperties(covering, {'labels': 'Urgent'}), isNotEmpty);
    });

    test('relation must be a list of wikilink strings', () {
      final covering = [
        _def(properties: {
          'owner': const PropertyDefinition(type: PropertyType.relation)
        }),
      ];
      expect(
          validateProperties(covering, {
            'owner': ['[[Alice]]']
          }),
          isEmpty);
      expect(
          validateProperties(covering, {
            'owner': ['Alice']
          }),
          isNotEmpty);
    });

    test('url must parse as absolute http(s)', () {
      final covering = [
        _def(properties: {
          'link': const PropertyDefinition(type: PropertyType.url)
        }),
      ];
      expect(validateProperties(covering, {'link': 'https://example.com'}),
          isEmpty);
      expect(validateProperties(covering, {'link': 'not a url'}), isNotEmpty);
      expect(validateProperties(covering, {'link': 'ftp://example.com'}),
          isNotEmpty);
    });

    test('reserved keys are rejected', () {
      final covering = [_def()];
      expect(validateProperties(covering, {'version': 5}), isNotEmpty);
      expect(validateProperties(covering, {'type': 'database'}), isNotEmpty);
    });

    test('built-ins are rejected as property write targets', () {
      final covering = [_def()];
      expect(validateProperties(covering, {'title': 'X'}), isNotEmpty);
      expect(
          validateProperties(covering, {
            'tags': ['x']
          }),
          isNotEmpty);
      expect(validateProperties(covering, {'created_at': '2026-01-01'}),
          isNotEmpty);
    });

    test('a nested map value is rejected regardless of type', () {
      final covering = [
        _def(properties: {
          'summary': const PropertyDefinition(type: PropertyType.text)
        }),
      ];
      expect(
          validateProperties(covering, {
            'summary': {'nested': 1}
          }),
          isNotEmpty);
    });

    test('null means unset and is never a violation', () {
      final covering = [
        _def(properties: {
          'status': const PropertyDefinition(
              type: PropertyType.select, options: ['Idea'])
        }),
      ];
      expect(validateProperties(covering, {'status': null}), isEmpty);
    });

    test('a key not declared by any covering database is accepted as free-form',
        () {
      final covering = [
        _def(properties: {
          'status': const PropertyDefinition(
              type: PropertyType.select, options: ['Idea'])
        }),
      ];
      expect(validateProperties(covering, {'mood': 'great'}), isEmpty);
    });

    test('a key declared by two databases is validated against both', () {
      final covering = [
        _def(id: 'db1', properties: {
          'status': const PropertyDefinition(
              type: PropertyType.select, options: ['Idea'])
        }),
        _def(id: 'db2', properties: {
          'status': const PropertyDefinition(
              type: PropertyType.select, options: ['Active'])
        }),
      ];
      // "Idea" satisfies db1 but not db2.
      final violations = validateProperties(covering, {'status': 'Idea'});
      expect(violations, isNotEmpty);
      expect(violations.single.key, 'status');
    });

    group('relation target constraint', () {
      final peopleDb = _def(id: 'people-db', title: 'People');
      final covering = [
        _def(
          id: 'projects-db',
          properties: {
            'owner': PropertyDefinition(
                type: PropertyType.relation, database: peopleDb.id),
          },
        ),
      ];

      test('a target that is a row of the constrained database is accepted',
          () {
        final alice = _note(title: 'Alice');
        final violations = validateProperties(
          covering,
          {
            'owner': ['[[Alice]]']
          },
          resolveTitle: (title) => title == 'Alice' ? alice : null,
          isRowOf: (note, dbId) => note.id == alice.id && dbId == peopleDb.id,
        );
        expect(violations, isEmpty);
      });

      test('a target that is not a row of the constrained database is rejected',
          () {
        final budget = _note(id: 'n2', title: 'Budget', path: 'Finance');
        final violations = validateProperties(
          covering,
          {
            'owner': ['[[Budget]]']
          },
          resolveTitle: (title) => title == 'Budget' ? budget : null,
          isRowOf: (note, dbId) => false,
        );
        expect(violations, isNotEmpty);
      });

      test('an unresolved title is accepted (dangling links allowed)', () {
        final violations = validateProperties(
          covering,
          {
            'owner': ['[[Nobody]]']
          },
          resolveTitle: (title) => null,
          isRowOf: (note, dbId) => false,
        );
        expect(violations, isEmpty);
      });

      test(
          'without a resolver/row-check, a constrained relation is still accepted',
          () {
        final violations = validateProperties(covering, {
          'owner': ['[[Alice]]']
        });
        expect(violations, isEmpty);
      });
    });
  });
}
