import 'dart:io';

import 'package:server/src/app_deps.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/invite_store.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/consent_throttle.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';
import 'package:test/test.dart';

const McpPrincipal fullAccess = McpPrincipal.staticKey('tester');
const McpPrincipal readOnly = McpPrincipal(
  actor: 'reader-bot',
  scopes: {kScopeNotesRead},
  isStaticKey: false,
);

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-mcp-db-tools-test-');

/// Builds an [AppDeps] wired with a live [DatabaseRegistry] — production
/// wiring (`AppDeps.bootstrap`) doesn't do this yet (see tasks.md 7.1), so
/// these tests build the stack by hand, the same way
/// `note_write_service_databases_test.dart` does.
Future<AppDeps> _bootstrap(Directory tmp) async {
  final clock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
  final storage =
      Storage(contentDir: Directory('${tmp.path}/content'), clock: clock);
  final metaIndex = MetaIndex();
  final linkIndex = LinkIndex();
  final searchIndex = await SearchIndex.open(
    dbFile: File('${tmp.path}/search.db'),
    storage: storage,
  );
  final registry = DatabaseRegistry();
  final broadcaster = Broadcaster();
  final lockManager = LockManager(clock: clock);
  final noteWriteService = NoteWriteService(
    storage: storage,
    metaIndex: metaIndex,
    searchIndex: searchIndex,
    broadcaster: broadcaster,
    linkIndex: linkIndex,
    lockManager: lockManager,
    registry: registry,
  );
  return AppDeps(
    storage: storage,
    metaIndex: metaIndex,
    searchIndex: searchIndex,
    inviteStore: InviteStore(inviteDir: Directory('${tmp.path}/invites')),
    clientStore: ClientStore(dir: Directory('${tmp.path}/oauth/clients')),
    codeStore: CodeStore(dir: Directory('${tmp.path}/oauth/codes')),
    tokenStore: TokenStore(dir: Directory('${tmp.path}/oauth/tokens')),
    consentThrottle: ConsentThrottle(),
    lockManager: lockManager,
    broadcaster: broadcaster,
    presence: PresenceTracker(),
    clock: clock,
    linkIndex: linkIndex,
    noteWriteService: noteWriteService,
  );
}

Map<String, Object?> _structured(Map<String, Object?> result) =>
    result['structuredContent']! as Map<String, Object?>;

void main() {
  late Directory tmp;
  late AppDeps deps;
  late McpToolRegistry registry;

  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> args, [
    McpPrincipal principal = fullAccess,
  ]) =>
      registry.call(name, args, principal);

  setUp(() async {
    tmp = _tempDir();
    deps = await _bootstrap(tmp);
    registry = McpToolRegistry.forDeps(deps);
  });

  tearDown(() async {
    await deps.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> makeDatabase({
    String title = 'Projects',
    Map<String, Object?> properties = const {
      'status': {
        'type': 'select',
        'options': ['Idea', 'Active', 'Done'],
      },
    },
    Map<String, Object?>? source,
  }) async {
    final result = await call('create_database', {
      'title': title,
      if (source != null) 'source': source,
      'properties': properties,
      'views': [
        {'name': 'All', 'type': 'table'},
      ],
    });
    return _structured(result);
  }

  group('6.1 _validateArgs type checks', () {
    test('object arg of wrong type is invalid params', () async {
      await expectLater(
        call('create_note', {'title': 'x', 'properties': 'nope'}),
        throwsA(isA<McpInvalidParamsException>()),
      );
    });

    test('array arg of wrong type is invalid params', () async {
      final db = await makeDatabase();
      await expectLater(
        call('query_database', {'id': db['id'], 'sort': 'nope'}),
        throwsA(isA<McpInvalidParamsException>()),
      );
    });

    test('query_database with filter as a string is invalid params', () async {
      final db = await makeDatabase();
      await expectLater(
        call('query_database', {'id': db['id'], 'filter': 'status=done'}),
        throwsA(isA<McpInvalidParamsException>()),
      );
    });

    test('boolean and number args of wrong type are invalid params', () async {
      final fakeTool = McpTool(
        name: 'fake_tool',
        description: 'test-only tool exercising boolean/number schema types',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'flag': {'type': 'boolean'},
            'count': {'type': 'number'},
          },
          'required': <String>[],
        },
        annotations: const {'title': 'Fake'},
        requiresWrite: false,
        handler: (args, principal) async => {},
      );
      final fakeRegistry = McpToolRegistry([fakeTool]);

      await expectLater(
        fakeRegistry.call('fake_tool', {'flag': 'nope'}, fullAccess),
        throwsA(isA<McpInvalidParamsException>()),
      );
      await expectLater(
        fakeRegistry.call('fake_tool', {'count': 'nope'}, fullAccess),
        throwsA(isA<McpInvalidParamsException>()),
      );
      // Correct types pass through without throwing.
      final ok = await fakeRegistry.call(
        'fake_tool',
        {'flag': true, 'count': 1.5},
        fullAccess,
      );
      expect(ok, isEmpty);
    });
  });

  group('6.2 properties on note tools', () {
    test('get_note returns properties', () async {
      final created = await deps.noteWriteService.create(
        title: 'Note',
        content: '',
        actor: 'x',
        properties: const {'status': 'Active'},
      );
      final result = await call('get_note', {'id': created.id});
      expect(_structured(result)['properties'], {'status': 'Active'});
    });

    test('create_note accepts properties', () async {
      final result = await call('create_note', {
        'title': 'Note',
        'properties': {'status': 'Active'},
      });
      expect(_structured(result)['properties'], {'status': 'Active'});
    });

    test('update_note with only properties is valid', () async {
      final created = await call('create_note', {'title': 'Note'});
      final id = _structured(created)['id'];
      final result = await call('update_note', {
        'id': id,
        'version': 1,
        'properties': {'status': 'Done'},
      });
      expect(_structured(result)['version'], 2);
      expect(_structured(result)['properties'], {'status': 'Done'});
    });
  });

  group('6.3 database CRUD tools', () {
    test('create_database creates a definition note', () async {
      final def = await makeDatabase();
      expect(def['title'], 'Projects');
      expect((def['properties']! as Map)['status'], isNotNull);
    });

    test('list_databases lists row_count', () async {
      final def = await makeDatabase();
      await call('create_row', {
        'id': def['id'],
        'title': 'Row 1',
        'properties': {'status': 'Idea'},
      });
      final result = await call('list_databases', {});
      final items = _structured(result)['items']! as List<Object?>;
      expect(items, hasLength(1));
      expect((items.first! as Map)['row_count'], 1);
    });

    test('get_database returns the schema', () async {
      final def = await makeDatabase();
      final result = await call('get_database', {'id': def['id']});
      final props = _structured(result)['properties']! as Map<String, Object?>;
      expect((props['status']! as Map)['type'], 'select');
      expect((props['status']! as Map)['options'], ['Idea', 'Active', 'Done']);
    });

    test('get_database unknown id is not_found', () async {
      final result = await call('get_database', {
        'id': '01ARZ3NDEKTSV4RRFFQ69G5FAV',
      });
      expect(_structured(result)['error'], 'not_found');
    });

    test('update_database replaces properties wholesale', () async {
      final def = await makeDatabase();
      final result = await call('update_database', {
        'id': def['id'],
        'version': def['version'],
        'properties': {
          'priority': {
            'type': 'select',
            'options': ['Low', 'High'],
          },
        },
      });
      final structured = _structured(result);
      final props = structured['properties']! as Map<String, Object?>;
      expect(props.containsKey('status'), isFalse);
      expect(props.containsKey('priority'), isTrue);
    });

    test('update_database with stale version is version_conflict', () async {
      final def = await makeDatabase();
      final result = await call('update_database', {
        'id': def['id'],
        'version': 999,
        'source': {'folder': 'Projects'},
      });
      expect(_structured(result)['error'], 'version_conflict');
    });

    test('create_database with a bad select is validation_failed', () async {
      final result = await call('create_database', {
        'title': 'Bad',
        'properties': {
          'status': {'type': 'select'},
        },
        'views': [
          {'name': 'All', 'type': 'table'},
        ],
      });
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('create_database colliding path is path_conflict', () async {
      await call('create_note', {'title': 'Taken'});
      final result = await call('create_database', {
        'title': 'Taken',
        'properties': const <String, Object?>{},
        'views': [
          {'name': 'All', 'type': 'table'},
        ],
      });
      expect(_structured(result)['error'], 'path_conflict');
    });

    test('create_database requires the write scope', () async {
      final result = await call(
        'create_database',
        {
          'title': 'X',
          'properties': const <String, Object?>{},
          'views': [
            {'name': 'All', 'type': 'table'},
          ],
        },
        readOnly,
      );
      expect(_structured(result)['error'], 'insufficient_scope');
    });
  });

  group('6.4 query_database, create_row, update_properties', () {
    test('create_row lands in the source folder and validates', () async {
      final def = await makeDatabase(source: const {'folder': 'Projects'});
      final result = await call('create_row', {
        'id': def['id'],
        'title': 'Rewrite',
        'properties': {'status': 'Idea'},
      });
      final note = _structured(result);
      expect(note['path'], 'Projects');
      expect(note['properties'], {'status': 'Idea'});
    });

    test('create_row with an invalid option is validation_failed', () async {
      final def = await makeDatabase();
      final result = await call('create_row', {
        'id': def['id'],
        'title': 'Bad',
        'properties': {'status': 'Blocked'},
      });
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('create_row for an unknown database is not_found', () async {
      final result = await call('create_row', {
        'id': '01ARZ3NDEKTSV4RRFFQ69G5FAV',
        'title': 'Row',
      });
      expect(_structured(result)['error'], 'not_found');
    });

    test('query_database returns rows with properties', () async {
      final def = await makeDatabase();
      await call('create_row', {
        'id': def['id'],
        'title': 'Row 1',
        'properties': {'status': 'Idea'},
      });
      await call('create_row', {
        'id': def['id'],
        'title': 'Row 2',
        'properties': {'status': 'Done'},
      });

      final result = await call('query_database', {'id': def['id']});
      final items = _structured(result)['items']! as List<Object?>;
      expect(items, hasLength(2));
    });

    test('query_database with a filter narrows rows', () async {
      final def = await makeDatabase();
      await call('create_row', {
        'id': def['id'],
        'title': 'Row 1',
        'properties': {'status': 'Idea'},
      });
      await call('create_row', {
        'id': def['id'],
        'title': 'Row 2',
        'properties': {'status': 'Done'},
      });

      final result = await call('query_database', {
        'id': def['id'],
        'filter': {
          'property': 'status',
          'op': 'eq',
          'value': 'Done',
        },
      });
      final items = _structured(result)['items']! as List<Object?>;
      expect(items, hasLength(1));
      expect(
        (items.first! as Map<String, Object?>)['title'],
        'Row 2',
      );
    });

    test('query_database with group_by returns groups', () async {
      final def = await makeDatabase();
      await call('create_row', {
        'id': def['id'],
        'title': 'Row 1',
        'properties': {'status': 'Idea'},
      });

      final result = await call('query_database', {
        'id': def['id'],
        'group_by': 'status',
      });
      expect(_structured(result)['groups'], isNotNull);
    });

    test('query_database allows the read scope', () async {
      final def = await makeDatabase();
      final result = await call('query_database', {'id': def['id']}, readOnly);
      expect(result['isError'], isNot(isTrue));
    });

    test('query_database rejects an inapplicable operator', () async {
      final def = await makeDatabase();
      final result = await call('query_database', {
        'id': def['id'],
        'filter': {'property': 'status', 'op': 'gt', 'value': 'Idea'},
      });
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('update_properties sets a property without a version', () async {
      final def = await makeDatabase();
      final row = _structured(
        await call('create_row', {
          'id': def['id'],
          'title': 'Row 1',
          'properties': {'status': 'Idea'},
        }),
      );
      final result = await call('update_properties', {
        'id': row['id'],
        'set': {'status': 'Done'},
      });
      final structured = _structured(result);
      expect(structured['properties'], {'status': 'Done'});
    });

    test('update_properties ignores the editor lock', () async {
      final def = await makeDatabase();
      final row = _structured(
        await call('create_row', {
          'id': def['id'],
          'title': 'Row 1',
          'properties': {'status': 'Idea'},
        }),
      );
      await deps.lockManager.acquire(
        noteId: row['id']! as String,
        actor: 'alice',
      );

      final result = await call('update_properties', {
        'id': row['id'],
        'set': {'status': 'Done'},
      });
      expect(result['isError'], isNot(isTrue));
    });

    test('update_properties with a bad value is validation_failed', () async {
      final def = await makeDatabase();
      final row = _structured(
        await call('create_row', {
          'id': def['id'],
          'title': 'Row 1',
          'properties': {'status': 'Idea'},
        }),
      );
      final result = await call('update_properties', {
        'id': row['id'],
        'set': {'status': 'Blocked'},
      });
      expect(_structured(result)['error'], 'validation_failed');
    });
  });
}
