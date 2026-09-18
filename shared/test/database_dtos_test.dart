import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('PropertyType', () {
    test('serialises to the spec\'s snake_case strings', () {
      expect(PropertyType.text.wire, 'text');
      expect(PropertyType.number.wire, 'number');
      expect(PropertyType.checkbox.wire, 'checkbox');
      expect(PropertyType.date.wire, 'date');
      expect(PropertyType.select.wire, 'select');
      expect(PropertyType.multiSelect.wire, 'multi_select');
      expect(PropertyType.relation.wire, 'relation');
      expect(PropertyType.url.wire, 'url');
      for (final t in PropertyType.values) {
        expect(PropertyType.fromWire(t.wire), t);
      }
    });
  });

  group('PropertyDefinition', () {
    test('round-trips a simple text property', () {
      const def = PropertyDefinition(type: PropertyType.text, label: 'Note');
      final json = def.toJson();
      expect(json, {'type': 'text', 'label': 'Note'});
      expect(PropertyDefinition.fromJson(json), def);
    });

    test('round-trips a select property with options', () {
      const def = PropertyDefinition(
        type: PropertyType.select,
        options: ['Idea', 'Active', 'Done'],
      );
      final json = def.toJson();
      expect(json['options'], ['Idea', 'Active', 'Done']);
      expect(PropertyDefinition.fromJson(json), def);
    });

    test('round-trips a multi_select property', () {
      const def = PropertyDefinition(
        type: PropertyType.multiSelect,
        options: ['a', 'b'],
      );
      expect(def.toJson()['type'], 'multi_select');
      expect(PropertyDefinition.fromJson(def.toJson()), def);
    });

    test('round-trips a relation with a constrained database', () {
      const def = PropertyDefinition(
        type: PropertyType.relation,
        database: 'db_people',
      );
      final json = def.toJson();
      expect(json['database'], 'db_people');
      expect(PropertyDefinition.fromJson(json), def);
    });
  });

  group('DatabaseSource', () {
    test('round-trips a folder source with default include_subfolders', () {
      const source = DatabaseSource.folder('Projects');
      final json = source.toJson();
      expect(json, {'folder': 'Projects', 'include_subfolders': true});
      expect(DatabaseSource.fromJson(json), source);
    });

    test('round-trips a folder source with include_subfolders false', () {
      const source =
          DatabaseSource.folder('Projects', includeSubfolders: false);
      final json = source.toJson();
      expect(json['include_subfolders'], false);
      expect(DatabaseSource.fromJson(json), source);
    });

    test('round-trips a tag source', () {
      const source = DatabaseSource.tag('project');
      final json = source.toJson();
      expect(json, {'tag': 'project'});
      expect(DatabaseSource.fromJson(json), source);
    });
  });

  group('SortSpec', () {
    test('round-trips both directions', () {
      const asc = SortSpec(property: 'due', direction: SortDirection.asc);
      const desc =
          SortSpec(property: 'updated_at', direction: SortDirection.desc);
      expect(asc.toJson(), {'property': 'due', 'direction': 'asc'});
      expect(desc.toJson(), {'property': 'updated_at', 'direction': 'desc'});
      expect(SortSpec.fromJson(asc.toJson()), asc);
      expect(SortSpec.fromJson(desc.toJson()), desc);
    });
  });

  group('Filter', () {
    test('round-trips a bare condition', () {
      const filter = Condition(
        property: 'status',
        op: FilterOp.eq,
        value: 'Done',
      );
      final json = filter.toJson();
      expect(json, {'property': 'status', 'op': 'eq', 'value': 'Done'});
      expect(Filter.fromJson(json), filter);
    });

    test('omits value for is_empty and is_not_empty', () {
      const empty = Condition(property: 'due', op: FilterOp.isEmpty);
      expect(empty.toJson(), {'property': 'due', 'op': 'is_empty'});
      expect(Filter.fromJson(empty.toJson()), empty);
    });

    test('round-trips every operator string', () {
      const wireByOp = {
        FilterOp.eq: 'eq',
        FilterOp.neq: 'neq',
        FilterOp.contains: 'contains',
        FilterOp.notContains: 'not_contains',
        FilterOp.isEmpty: 'is_empty',
        FilterOp.isNotEmpty: 'is_not_empty',
        FilterOp.gt: 'gt',
        FilterOp.gte: 'gte',
        FilterOp.lt: 'lt',
        FilterOp.lte: 'lte',
      };
      for (final entry in wireByOp.entries) {
        expect(entry.key.wire, entry.value);
      }
    });

    test('round-trips a nested and/or combinator', () {
      const filter = And([
        Condition(property: 'status', op: FilterOp.neq, value: 'Done'),
        Or([
          Condition(property: 'due', op: FilterOp.isEmpty),
          Condition(property: 'due', op: FilterOp.lte, value: '2026-12-31'),
        ]),
      ]);
      final json = filter.toJson();
      expect(json, {
        'and': [
          {'property': 'status', 'op': 'neq', 'value': 'Done'},
          {
            'or': [
              {'property': 'due', 'op': 'is_empty'},
              {'property': 'due', 'op': 'lte', 'value': '2026-12-31'},
            ],
          },
        ],
      });
      final back = Filter.fromJson(json);
      expect(back, filter);
    });
  });

  group('ViewDefinition', () {
    test('round-trips a table view with sort and columns', () {
      const view = ViewDefinition(
        name: 'All',
        type: ViewType.table,
        sort: [SortSpec(property: 'due', direction: SortDirection.asc)],
        properties: ['status', 'due'],
      );
      final json = view.toJson();
      expect(json['type'], 'table');
      expect(json['sort'], [
        {'property': 'due', 'direction': 'asc'},
      ]);
      expect(ViewDefinition.fromJson(json), view);
    });

    test('round-trips a board view with filter and group_by', () {
      const view = ViewDefinition(
        name: 'Kanban',
        type: ViewType.board,
        filter: Condition(property: 'status', op: FilterOp.neq, value: 'x'),
        groupBy: 'status',
      );
      final json = view.toJson();
      expect(json['type'], 'board');
      expect(json['group_by'], 'status');
      expect(json['filter'], isNotNull);
      expect(ViewDefinition.fromJson(json), view);
    });

    test('round-trips a list view with no optional fields', () {
      const view = ViewDefinition(name: 'Quick', type: ViewType.list);
      final json = view.toJson();
      expect(json.containsKey('filter'), isFalse);
      expect(json.containsKey('sort'), isFalse);
      expect(json.containsKey('group_by'), isFalse);
      expect(json.containsKey('properties'), isFalse);
      expect(ViewDefinition.fromJson(json), view);
    });
  });

  group('DatabaseDefinition', () {
    test('round-trips a full definition', () {
      final def = DatabaseDefinition(
        id: '01HXY00000000000000000000A',
        title: 'Projects',
        path: 'Projects',
        version: 1,
        source: const DatabaseSource.folder('Projects'),
        properties: const {
          'status': PropertyDefinition(
            type: PropertyType.select,
            options: ['Idea', 'Active', 'Done'],
          ),
        },
        views: const [ViewDefinition(name: 'All', type: ViewType.table)],
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      final json = def.toJson();
      expect(json['properties'], {
        'status': {
          'type': 'select',
          'options': ['Idea', 'Active', 'Done'],
        },
      });
      final back = DatabaseDefinition.fromJson(json);
      expect(back, equals(def));
    });
  });

  group('DatabaseSummary', () {
    test('round-trips with row_count', () {
      const summary = DatabaseSummary(
        id: '01HXY00000000000000000000A',
        title: 'Projects',
        path: 'Projects',
        source: DatabaseSource.folder('Projects'),
        rowCount: 3,
      );
      final json = summary.toJson();
      expect(json['row_count'], 3);
      expect(DatabaseSummary.fromJson(json), summary);
    });
  });

  group('DatabaseRow', () {
    test('round-trips with properties and invalid keys', () {
      final row = DatabaseRow(
        id: '01HXY00000000000000000000A',
        title: 'Rewrite',
        path: 'Projects/Rewrite',
        version: 1,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        tags: const ['urgent'],
        properties: const {'status': 'Blocked'},
        invalid: const ['status'],
      );
      final json = row.toJson();
      expect(json['invalid'], ['status']);
      final back = DatabaseRow.fromJson(json);
      expect(back, equals(row));
    });
  });

  group('GroupCount', () {
    test('round-trips with a null value bucket', () {
      const g = GroupCount(value: null, count: 1);
      final json = g.toJson();
      expect(json, {'value': null, 'count': 1});
      expect(GroupCount.fromJson(json), g);
    });
  });

  group('DatabaseQueryPage', () {
    test('round-trips items, next_cursor, and groups', () {
      final page = DatabaseQueryPage(
        items: [
          DatabaseRow(
            id: '01HXY00000000000000000000A',
            title: 'Rewrite',
            version: 1,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        nextCursor: 'abc123',
        groups: const [
          GroupCount(value: 'Idea', count: 2),
          GroupCount(value: null, count: 1),
        ],
      );
      final json = page.toJson();
      expect(json['next_cursor'], 'abc123');
      expect(json['groups'], [
        {'value': 'Idea', 'count': 2},
        {'value': null, 'count': 1},
      ]);
      final back = DatabaseQueryPage.fromJson(json);
      expect(back, equals(page));
    });

    test('next_cursor is null and groups omitted when absent', () {
      final page = DatabaseQueryPage(items: const []);
      final json = page.toJson();
      expect(json['next_cursor'], isNull);
      expect(json.containsKey('groups'), isFalse);
      final back = DatabaseQueryPage.fromJson(json);
      expect(back, equals(page));
    });
  });

  group('PropertyPatch', () {
    test('round-trips set and unset', () {
      const patch = PropertyPatch(
        set: {'status': 'Active'},
        unset: ['mood'],
      );
      final json = patch.toJson();
      expect(json, {
        'set': {'status': 'Active'},
        'unset': ['mood'],
      });
      expect(PropertyPatch.fromJson(json), patch);
    });
  });

  group('coveringDatabases', () {
    DatabaseDefinition folderDef({
      required String id,
      required String defPath,
      required String folder,
      bool includeSubfolders = true,
    }) =>
        DatabaseDefinition(
          id: id,
          title: id,
          path: defPath,
          version: 1,
          source: DatabaseSource.folder(
            folder,
            includeSubfolders: includeSubfolders,
          ),
          properties: const {},
          views: const [ViewDefinition(name: 'All', type: ViewType.table)],
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        );

    test('matches a note under the folder prefix with subfolders', () {
      final def = folderDef(
        id: 'db1',
        defPath: 'Projects/Projects',
        folder: 'Projects',
      );
      final result = coveringDatabases('Projects/Alpha', const [], [def]);
      expect(result, [def]);
    });

    test('excludes a note outside the folder prefix', () {
      final def = folderDef(
        id: 'db1',
        defPath: 'Projects/Projects',
        folder: 'Projects',
      );
      final result = coveringDatabases('Archive/Alpha', const [], [def]);
      expect(result, isEmpty);
    });

    test('excludes subfolders when include_subfolders is false', () {
      final def = folderDef(
        id: 'db1',
        defPath: 'Projects/Projects',
        folder: 'Projects',
        includeSubfolders: false,
      );
      final result = coveringDatabases('Projects/Alpha', const [], [def]);
      expect(result, isEmpty);
    });

    test('matches by tag membership', () {
      final def = DatabaseDefinition(
        id: 'db1',
        title: 'db1',
        path: 'People',
        version: 1,
        source: const DatabaseSource.tag('project'),
        properties: const {},
        views: const [ViewDefinition(name: 'All', type: ViewType.table)],
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final result = coveringDatabases('Anywhere', const ['project'], [def]);
      expect(result, [def]);
    });

    test('never returns a definition for itself', () {
      final def = folderDef(
        id: 'db1',
        defPath: 'Projects',
        folder: 'Projects',
      );
      final result = coveringDatabases('Projects', const [], [def]);
      expect(result, isEmpty);
    });
  });
}
