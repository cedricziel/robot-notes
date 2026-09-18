import 'package:server/src/databases/registry.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

NoteSummary _summary({
  required String id,
  required String title,
  required String path,
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
  group('DatabaseRegistry', () {
    test('rebuild registers valid definitions', () {
      final registry = DatabaseRegistry();
      final summary = _summary(id: 'db1', title: 'Projects', path: 'Projects');
      registry.rebuild([
        (
          summary,
          {
            'type': 'database',
            'properties': <String, Object?>{
              'status': {
                'type': 'select',
                'options': ['Idea', 'Active', 'Done'],
              },
            },
            'views': [
              {'name': 'All', 'type': 'table'},
            ],
          },
        ),
      ]);
      expect(registry.get('db1'), isNotNull);
      expect(registry.get('db1')!.title, 'Projects');
      expect(registry.all, hasLength(1));
    });

    test('rebuild skips a definition with an invalid schema, logging it', () {
      final registry = DatabaseRegistry();
      final summary = _summary(id: 'db1', title: 'Projects', path: 'Projects');
      registry.rebuild([
        (
          summary,
          {
            'type': 'database',
            'properties': <String, Object?>{
              'version': {'type': 'text'}, // reserved key -> invalid
            },
            'views': [
              {'name': 'All', 'type': 'table'},
            ],
          },
        ),
      ]);
      expect(registry.get('db1'), isNull);
      expect(registry.all, isEmpty);
    });

    test('rebuild skips a definition that fails to parse structurally', () {
      final registry = DatabaseRegistry();
      final summary = _summary(id: 'db1', title: 'Projects', path: 'Projects');
      registry.rebuild([
        (summary, {'type': 'database', 'views': 'not-a-list'}),
      ]);
      expect(registry.get('db1'), isNull);
    });

    test('rebuild skips a note that is not a database definition at all', () {
      final registry = DatabaseRegistry();
      final summary = _summary(id: 'n1', title: 'Note', path: '');
      registry.rebuild([
        (summary, {'mood': 'great'}),
      ]);
      expect(registry.get('n1'), isNull);
      expect(registry.all, isEmpty);
    });

    test('upsert adds a new definition and updates an existing one', () {
      final registry = DatabaseRegistry();
      final summary = _summary(id: 'db1', title: 'Projects', path: 'Projects');
      registry.upsert(summary, {
        'type': 'database',
        'views': [
          {'name': 'All', 'type': 'table'},
        ],
      });
      expect(registry.get('db1'), isNotNull);

      final renamed =
          _summary(id: 'db1', title: 'Projects 2', path: 'Projects');
      registry.upsert(renamed, {
        'type': 'database',
        'views': [
          {'name': 'All', 'type': 'table'},
        ],
      });
      expect(registry.get('db1')!.title, 'Projects 2');
      expect(registry.all, hasLength(1));
    });

    test('upsert unregisters a note that no longer carries type: database', () {
      final registry = DatabaseRegistry();
      final summary = _summary(id: 'db1', title: 'Projects', path: 'Projects');
      registry.upsert(summary, {
        'type': 'database',
        'views': [
          {'name': 'All', 'type': 'table'},
        ],
      });
      expect(registry.get('db1'), isNotNull);

      registry.upsert(summary, {'mood': 'great'});
      expect(registry.get('db1'), isNull);
    });

    test('remove unregisters a database', () {
      final registry = DatabaseRegistry();
      final summary = _summary(id: 'db1', title: 'Projects', path: 'Projects');
      registry.upsert(summary, {
        'type': 'database',
        'views': [
          {'name': 'All', 'type': 'table'},
        ],
      });
      registry.remove('db1');
      expect(registry.get('db1'), isNull);
    });

    test('covering returns definitions whose source matches', () {
      final registry = DatabaseRegistry();
      final projectsDb =
          _summary(id: 'db1', title: 'Projects', path: 'Projects');
      registry.rebuild([
        (
          projectsDb,
          {
            'type': 'database',
            'views': [
              {'name': 'All', 'type': 'table'},
            ],
          },
        ),
      ]);

      final covering = registry.covering('Projects/Alpha', {});
      expect(covering.map((d) => d.id), contains('db1'));

      final notCovering = registry.covering('Archive', {});
      expect(notCovering, isEmpty);
    });

    test('covering never returns a definition for its own note', () {
      final registry = DatabaseRegistry();
      final projectsDb =
          _summary(id: 'db1', title: 'Projects', path: 'Projects');
      registry.rebuild([
        (
          projectsDb,
          {
            'type': 'database',
            'views': [
              {'name': 'All', 'type': 'table'},
            ],
          },
        ),
      ]);

      expect(registry.covering('Projects', {}, noteId: 'db1'), isEmpty);
      expect(
        registry.covering('Projects', {}, noteId: 'row1'),
        isNotEmpty,
        reason: 'sibling notes in the definition folder are rows',
      );
      expect(
        registry.covering('Projects', {}, noteId: 'db2', isDefinition: true),
        isEmpty,
        reason: 'a definition note is never a row',
      );
    });

    test('covering matches a tag source', () {
      final registry = DatabaseRegistry();
      final summary = _summary(id: 'db1', title: 'Tagged', path: '');
      registry.rebuild([
        (
          summary,
          {
            'type': 'database',
            'source': {'tag': 'project'},
            'views': [
              {'name': 'All', 'type': 'table'},
            ],
          },
        ),
      ]);

      expect(registry.covering('Anywhere', {'project'}), isNotEmpty);
      expect(registry.covering('Anywhere', {'other'}), isEmpty);
    });
  });
}
