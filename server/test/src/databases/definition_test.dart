import 'package:server/src/databases/definition.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('isDatabaseDefinitionExtra', () {
    test('true when frontmatter carries type: database', () {
      expect(isDatabaseDefinitionExtra({'type': 'database'}), isTrue);
    });

    test('false otherwise', () {
      expect(isDatabaseDefinitionExtra({'type': 'note'}), isFalse);
      expect(isDatabaseDefinitionExtra({}), isFalse);
    });
  });

  group('parseDatabaseDefinition', () {
    test('throws when extra does not carry type: database', () {
      expect(
        () => parseDatabaseDefinition(
          id: 'n1',
          title: 'Projects',
          path: 'Projects',
          extra: {},
        ),
        throwsA(isA<DefinitionFormatException>()),
      );
    });

    test('defaults source to own folder with subfolders included', () {
      final def = parseDatabaseDefinition(
        id: 'n1',
        title: 'Projects',
        path: 'Projects',
        extra: {'type': 'database'},
      );
      expect(def.source, DatabaseSource.folder('Projects'));
      expect(def.source.includeSubfolders, isTrue);
      expect(def.properties, isEmpty);
      expect(def.views, isEmpty);
    });

    test('parses an explicit folder source', () {
      final def = parseDatabaseDefinition(
        id: 'n1',
        title: 'Projects',
        path: 'Projects',
        extra: {
          'type': 'database',
          'source': {'folder': 'Work/Active', 'include_subfolders': false},
        },
      );
      expect(def.source,
          DatabaseSource.folder('Work/Active', includeSubfolders: false));
    });

    test('parses an explicit tag source', () {
      final def = parseDatabaseDefinition(
        id: 'n1',
        title: 'Projects',
        path: 'Projects',
        extra: {
          'type': 'database',
          'source': {'tag': 'project'},
        },
      );
      expect(def.source, DatabaseSource.tag('project'));
    });

    test('parses every property type', () {
      final def = parseDatabaseDefinition(
        id: 'n1',
        title: 'Projects',
        path: 'Projects',
        extra: {
          'type': 'database',
          'properties': {
            'summary': {'type': 'text'},
            'budget': {'type': 'number'},
            'done': {'type': 'checkbox'},
            'due': {'type': 'date'},
            'status': {
              'type': 'select',
              'options': ['Idea', 'Active', 'Done'],
            },
            'labels': {
              'type': 'multi_select',
              'options': ['Urgent', 'Blocked'],
            },
            'owner': {'type': 'relation', 'database': 'people-db'},
            'link': {'type': 'url'},
          },
        },
      );
      expect(def.properties['summary']!.type, PropertyType.text);
      expect(def.properties['budget']!.type, PropertyType.number);
      expect(def.properties['done']!.type, PropertyType.checkbox);
      expect(def.properties['due']!.type, PropertyType.date);
      expect(def.properties['status']!.type, PropertyType.select);
      expect(def.properties['status']!.options, ['Idea', 'Active', 'Done']);
      expect(def.properties['labels']!.type, PropertyType.multiSelect);
      expect(def.properties['owner']!.type, PropertyType.relation);
      expect(def.properties['owner']!.database, 'people-db');
      expect(def.properties['link']!.type, PropertyType.url);
    });

    test('throws on an unknown property type', () {
      expect(
        () => parseDatabaseDefinition(
          id: 'n1',
          title: 'Projects',
          path: 'Projects',
          extra: {
            'type': 'database',
            'properties': {
              'formula': {'type': 'formula'},
            },
          },
        ),
        throwsA(isA<DefinitionFormatException>()),
      );
    });

    test('parses views', () {
      final def = parseDatabaseDefinition(
        id: 'n1',
        title: 'Projects',
        path: 'Projects',
        extra: {
          'type': 'database',
          'properties': {
            'status': {
              'type': 'select',
              'options': ['Idea', 'Active', 'Done'],
            },
          },
          'views': [
            {
              'name': 'All',
              'type': 'table',
            },
            {
              'name': 'Kanban',
              'type': 'board',
              'group_by': 'status',
              'filter': {
                'property': 'status',
                'op': 'neq',
                'value': 'Done',
              },
              'sort': [
                {'property': 'status', 'direction': 'asc'},
              ],
              'properties': ['status'],
            },
          ],
        },
      );
      expect(def.views, hasLength(2));
      expect(def.views[0].name, 'All');
      expect(def.views[0].type, ViewType.table);
      expect(def.views[1].name, 'Kanban');
      expect(def.views[1].type, ViewType.board);
      expect(def.views[1].groupBy, 'status');
      expect(def.views[1].filter, isA<Condition>());
      expect(def.views[1].sort,
          [const SortSpec(property: 'status', direction: SortDirection.asc)]);
      expect(def.views[1].properties, ['status']);
    });

    test('throws when views is not a list', () {
      expect(
        () => parseDatabaseDefinition(
          id: 'n1',
          title: 'Projects',
          path: 'Projects',
          extra: {'type': 'database', 'views': 'nope'},
        ),
        throwsA(isA<DefinitionFormatException>()),
      );
    });

    test('threads through id, title, path, version, and timestamps', () {
      final createdAt = DateTime.utc(2026, 1, 1);
      final updatedAt = DateTime.utc(2026, 2, 1);
      final def = parseDatabaseDefinition(
        id: 'n1',
        title: 'Projects',
        path: 'Projects',
        extra: {'type': 'database'},
        version: 3,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
      expect(def.id, 'n1');
      expect(def.title, 'Projects');
      expect(def.path, 'Projects');
      expect(def.version, 3);
      expect(def.createdAt, createdAt);
      expect(def.updatedAt, updatedAt);
    });
  });
}
