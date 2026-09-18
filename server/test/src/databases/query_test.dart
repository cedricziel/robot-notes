import 'dart:io';

import 'package:server/src/databases/query.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-query-test-');

final _stamp = DateTime.utc(2026);

void main() {
  late Directory tmp;
  late SearchIndex index;
  late DatabaseQuery query;

  setUp(() async {
    tmp = _tempDir();
    index = await SearchIndex.open(
      dbFile: File('${tmp.path}/search.db'),
      storage: Storage(contentDir: Directory('${tmp.path}/content')),
    );
    query = DatabaseQuery(index.rawDb);
  });

  tearDown(() {
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void upsertRow(
    String id, {
    String path = 'Projects',
    Map<String, Object?> extra = const {},
    DateTime? updatedAt,
    Set<String> tags = const {},
  }) {
    index.upsert(
      id: id,
      title: id,
      content: '',
      path: path,
      updatedAt: updatedAt ?? _stamp,
      extra: extra,
      tags: tags,
    );
  }

  void upsertDefinition(String id, {String path = 'Projects'}) {
    index.upsert(
      id: id,
      title: id,
      content: '',
      path: path,
      updatedAt: _stamp,
      isDefinition: true,
      extra: const {'type': 'database'},
    );
  }

  group('source narrowing (3.5)', () {
    test('folder source with subfolders includes nested notes', () {
      upsertRow('a', path: 'Projects');
      upsertRow('b', path: 'Projects/Sub');
      upsertRow('c', path: 'Other');

      final page = query.run(source: const DatabaseSource.folder('Projects'));
      expect(page.items.map((r) => r.id).toSet(), {'a', 'b'});
    });

    test('folder source without subfolders excludes nested notes', () {
      upsertRow('a', path: 'Projects');
      upsertRow('b', path: 'Projects/Sub');

      final page = query.run(
        source: const DatabaseSource.folder(
          'Projects',
          includeSubfolders: false,
        ),
      );
      expect(page.items.map((r) => r.id).toSet(), {'a'});
    });

    test('tag source matches by computed tag regardless of folder', () {
      upsertRow('a', path: 'Projects', tags: {'project'});
      upsertRow('b', path: 'Other', tags: {'project'});
      upsertRow('c', path: 'Projects', tags: {});

      final page = query.run(source: const DatabaseSource.tag('project'));
      expect(page.items.map((r) => r.id).toSet(), {'a', 'b'});
    });

    test('definition notes are always excluded', () {
      upsertRow('a', path: 'Projects');
      upsertDefinition('def', path: 'Projects');

      final page = query.run(source: const DatabaseSource.folder('Projects'));
      expect(page.items.map((r) => r.id), ['a']);
    });

    test('excludeIds removes specific note ids on top of source', () {
      upsertRow('a', path: 'Projects');
      upsertRow('b', path: 'Projects');

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        excludeIds: const ['a'],
      );
      expect(page.items.map((r) => r.id), ['b']);
    });
  });

  group('condition compilation (3.6)', () {
    test('eq on a select-like text property', () {
      upsertRow('a', extra: const {'status': 'Idea'});
      upsertRow('b', extra: const {'status': 'Active'});

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(
          property: 'status',
          op: FilterOp.eq,
          value: 'Active',
        ),
      );
      expect(page.items.map((r) => r.id), ['b']);
    });

    test('neq matches other values and unset rows', () {
      upsertRow('a', extra: const {'status': 'Done'});
      upsertRow('b', extra: const {'status': 'Active'});
      upsertRow('c');

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(
          property: 'status',
          op: FilterOp.neq,
          value: 'Done',
        ),
      );
      expect(page.items.map((r) => r.id).toSet(), {'b', 'c'});
    });

    test('contains is ASCII case-insensitive substring', () {
      upsertRow('a', extra: const {'title_text': 'Budget Review'});

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(
          property: 'title_text',
          op: FilterOp.contains,
          value: 'budget',
        ),
      );
      expect(page.items.map((r) => r.id), ['a']);
    });

    test('contains matches membership in a list-valued property', () {
      upsertRow(
        'a',
        extra: const {
          'labels': ['alpha', 'beta'],
        },
      );
      upsertRow(
        'b',
        extra: const {
          'labels': ['gamma'],
        },
      );

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(
          property: 'labels',
          op: FilterOp.contains,
          value: 'beta',
        ),
      );
      expect(page.items.map((r) => r.id), ['a']);
    });

    test('is_empty matches missing, empty string, and empty list', () {
      upsertRow('missing');
      upsertRow('empty_string', extra: const {'note': ''});
      upsertRow(
        'empty_list',
        extra: const {'note': <String>[]},
      );
      upsertRow('has_value', extra: const {'note': 'x'});

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(property: 'note', op: FilterOp.isEmpty),
      );
      expect(
        page.items.map((r) => r.id).toSet(),
        {'missing', 'empty_string', 'empty_list'},
      );
    });

    test('gt/gte/lt/lte compare numbers', () {
      upsertRow('a', extra: const {'budget': 10});
      upsertRow('b', extra: const {'budget': 20});
      upsertRow('c', extra: const {'budget': 30});

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(
          property: 'budget',
          op: FilterOp.gte,
          value: 20,
        ),
      );
      expect(page.items.map((r) => r.id).toSet(), {'b', 'c'});
    });

    test('same-day timestamp satisfies a day-only lte', () {
      upsertRow('a', extra: const {'due': '2026-10-01T09:00:00Z'});
      upsertRow('b', extra: const {'due': '2026-10-02T09:00:00Z'});

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(
          property: 'due',
          op: FilterOp.lte,
          value: '2026-10-01',
        ),
      );
      expect(page.items.map((r) => r.id), ['a']);
    });

    test('eq on a date compares the calendar day, not the instant', () {
      upsertRow('a', extra: const {'due': '2026-10-01T09:00:00Z'});

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(
          property: 'due',
          op: FilterOp.eq,
          value: '2026-10-01',
        ),
      );
      expect(page.items.map((r) => r.id), ['a']);
    });

    test('built-in updated_at supports range comparison', () {
      upsertRow('a', updatedAt: DateTime.utc(2026, 1, 1));
      upsertRow('b', updatedAt: DateTime.utc(2026, 6, 1));

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const Condition(
          property: 'updated_at',
          op: FilterOp.gt,
          value: '2026-03-01',
        ),
      );
      expect(page.items.map((r) => r.id), ['b']);
    });
  });

  group('combinators (3.7)', () {
    test('nested and/or', () {
      upsertRow(
        'idea_undated',
        extra: const {'status': 'Idea'},
      );
      upsertRow(
        'active_due_soon',
        extra: const {'status': 'Active', 'due': '2026-06-01'},
      );
      upsertRow(
        'active_due_late',
        extra: const {'status': 'Active', 'due': '2027-01-01'},
      );
      upsertRow('done', extra: const {'status': 'Done'});

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        filter: const And([
          Condition(property: 'status', op: FilterOp.neq, value: 'Done'),
          Or([
            Condition(property: 'due', op: FilterOp.isEmpty),
            Condition(
              property: 'due',
              op: FilterOp.lte,
              value: '2026-12-31',
            ),
          ]),
        ]),
      );
      expect(
        page.items.map((r) => r.id).toSet(),
        {'idea_undated', 'active_due_soon'},
      );
    });
  });

  group('sort (3.8)', () {
    test('sorts by built-in updated_at descending', () {
      upsertRow('a', updatedAt: DateTime.utc(2026, 1, 1));
      upsertRow('b', updatedAt: DateTime.utc(2026, 3, 1));
      upsertRow('c', updatedAt: DateTime.utc(2026, 2, 1));

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        sort: const [
          SortSpec(property: 'updated_at', direction: SortDirection.desc),
        ],
      );
      expect(page.items.map((r) => r.id), ['b', 'c', 'a']);
    });

    test('unset values sort last in both directions', () {
      upsertRow('has_low', extra: const {'budget': 1});
      upsertRow('unset');
      upsertRow('has_high', extra: const {'budget': 9});

      final asc = query.run(
        source: const DatabaseSource.folder('Projects'),
        sort: const [
          SortSpec(property: 'budget', direction: SortDirection.asc),
        ],
      );
      expect(asc.items.map((r) => r.id), ['has_low', 'has_high', 'unset']);

      final desc = query.run(
        source: const DatabaseSource.folder('Projects'),
        sort: const [
          SortSpec(property: 'budget', direction: SortDirection.desc),
        ],
      );
      expect(desc.items.map((r) => r.id), ['has_high', 'has_low', 'unset']);
    });

    test('default order (no sort) is id ascending', () {
      upsertRow('c');
      upsertRow('a');
      upsertRow('b');

      final page = query.run(source: const DatabaseSource.folder('Projects'));
      expect(page.items.map((r) => r.id), ['a', 'b', 'c']);
    });

    test('id is the final tie-break', () {
      upsertRow('b', extra: const {'status': 'Idea'});
      upsertRow('a', extra: const {'status': 'Idea'});

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        sort: const [
          SortSpec(property: 'status', direction: SortDirection.asc),
        ],
      );
      expect(page.items.map((r) => r.id), ['a', 'b']);
    });
  });

  group('pagination (3.9)', () {
    test('three pages over 120 rows contain 50, 50, 20 distinct rows', () {
      for (var i = 0; i < 120; i++) {
        upsertRow('n${i.toString().padLeft(3, '0')}');
      }

      final page1 = query.run(
        source: const DatabaseSource.folder('Projects'),
        limit: 50,
      );
      expect(page1.items, hasLength(50));
      expect(page1.nextCursor, isNotNull);

      final page2 = query.run(
        source: const DatabaseSource.folder('Projects'),
        limit: 50,
        after: page1.nextCursor,
      );
      expect(page2.items, hasLength(50));
      expect(page2.nextCursor, isNotNull);

      final page3 = query.run(
        source: const DatabaseSource.folder('Projects'),
        limit: 50,
        after: page2.nextCursor,
      );
      expect(page3.items, hasLength(20));
      expect(page3.nextCursor, isNull);

      final allIds = [
        ...page1.items.map((r) => r.id),
        ...page2.items.map((r) => r.id),
        ...page3.items.map((r) => r.id),
      ];
      expect(allIds.toSet(), hasLength(120));
    });

    test('a cursor produced under a different sort is rejected', () {
      upsertRow('a');
      upsertRow('b');

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        limit: 1,
      );
      expect(page.nextCursor, isNotNull);

      expect(
        () => query.run(
          source: const DatabaseSource.folder('Projects'),
          limit: 1,
          after: page.nextCursor,
          sort: const [
            SortSpec(property: 'title', direction: SortDirection.asc),
          ],
        ),
        throwsA(isA<InvalidCursorException>()),
      );
    });
  });

  group('group counts (3.10)', () {
    test('select-typed group_by follows option order with zero buckets', () {
      upsertRow('a', extra: const {'status': 'Idea'});
      upsertRow('b', extra: const {'status': 'Idea'});
      upsertRow('c', extra: const {'status': 'Active'});
      upsertRow('d', extra: const {'status': 'Active'});
      upsertRow('e', extra: const {'status': 'Active'});
      upsertRow('f');

      final page = query.run(
        source: const DatabaseSource.folder('Projects'),
        groupBy: 'status',
        groupByOptions: const ['Idea', 'Active', 'Done'],
      );
      expect(page.groups, [
        const GroupCount(value: 'Idea', count: 2),
        const GroupCount(value: 'Active', count: 3),
        const GroupCount(value: 'Done', count: 0),
        const GroupCount(value: null, count: 1),
      ]);
    });

    test(
      'non-select group_by is distinct values ascending with a trailing '
      'null bucket',
      () {
        upsertRow('a', extra: const {'owner': 'Zed'});
        upsertRow('b', extra: const {'owner': 'Amy'});
        upsertRow('c', extra: const {'owner': 'Amy'});
        upsertRow('d');

        final page = query.run(
          source: const DatabaseSource.folder('Projects'),
          groupBy: 'owner',
        );
        expect(page.groups, [
          const GroupCount(value: 'Amy', count: 2),
          const GroupCount(value: 'Zed', count: 1),
          const GroupCount(value: null, count: 1),
        ]);
      },
    );
  });

  group('row_count', () {
    test('counts the source without a filter', () {
      upsertRow('a');
      upsertRow('b');
      upsertDefinition('def');

      expect(
        query.rowCount(source: const DatabaseSource.folder('Projects')),
        2,
      );
    });
  });

  group('benchmark (3.11)', () {
    test(
      '5,000 rows with a two-condition filter, sort, and limit 50 stays '
      'under 2s',
      () {
        for (var i = 0; i < 5000; i++) {
          upsertRow(
            'n${i.toString().padLeft(5, '0')}',
            extra: {
              'status': ['Idea', 'Active', 'Done'][i % 3],
              'budget': i,
              'priority': i % 10,
              'owner': 'owner${i % 25}',
              'due': '2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}',
            },
          );
        }

        final stopwatch = Stopwatch()..start();
        final page = query.run(
          source: const DatabaseSource.folder('Projects'),
          filter: const And([
            Condition(property: 'status', op: FilterOp.neq, value: 'Done'),
            Condition(property: 'budget', op: FilterOp.gte, value: 100),
          ]),
          sort: const [
            SortSpec(property: 'budget', direction: SortDirection.asc),
          ],
          limit: 50,
        );
        stopwatch.stop();

        // ignore: avoid_print
        print(
            'benchmark: query over 5000 rows took ${stopwatch.elapsedMilliseconds}ms');
        expect(page.items, hasLength(50));
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );
  });
}
