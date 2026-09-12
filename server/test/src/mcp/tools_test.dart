import 'dart:async';
import 'dart:io';

import 'package:server/src/app_deps.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tool_results.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const McpPrincipal fullAccess = McpPrincipal.staticKey('tester');
const McpPrincipal readOnly = McpPrincipal(
  actor: 'reader-bot',
  scopes: {kScopeNotesRead},
  isStaticKey: false,
);
const McpPrincipal writeOnly = McpPrincipal(
  actor: 'writer-bot',
  scopes: {kScopeNotesWrite},
  isStaticKey: false,
);
const McpPrincipal bob = McpPrincipal.staticKey('bob');

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-mcp-tools-test-');

Future<AppDeps> _bootstrap(Directory tmp, {Clock? clock}) {
  final config = Config(
    apiKey: 'test-key',
    dataDir: tmp.path,
    port: 0,
    lockTtlSeconds: 60,
  );
  return AppDeps.bootstrap(config, clock: clock ?? const Clock());
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

  group('list_notes', () {
    test('paginates with an explicit limit and honours a cursor', () async {
      await deps.noteWriteService.create(title: 'a', content: '', actor: 'x');
      await deps.noteWriteService.create(title: 'b', content: '', actor: 'x');
      await deps.noteWriteService.create(title: 'c', content: '', actor: 'x');

      final page1 = await call('list_notes', {'limit': 2});
      final s1 = _structured(page1);
      expect(s1['items']! as List<Object?>, hasLength(2));
      expect(s1['next_cursor'], isNotNull);

      final page2 = await call('list_notes', {'after': s1['next_cursor']});
      final s2 = _structured(page2);
      expect(s2['items']! as List<Object?>, hasLength(1));
      expect(s2['next_cursor'], isNull);
    });

    test('defaults to the same page size as GET /notes', () async {
      final result = await call('list_notes', {});
      expect(_structured(result)['items'], isEmpty);
    });

    test('rejects a limit outside 1..200 as an invalid param', () async {
      await expectLater(
        call('list_notes', {'limit': 500}),
        throwsA(isA<McpInvalidParamsException>()),
      );
      await expectLater(
        call('list_notes', {'limit': 0}),
        throwsA(isA<McpInvalidParamsException>()),
      );
    });
  });

  group('get_note', () {
    test('includes lock only while an editor lock is active', () async {
      final note = await deps.noteWriteService.create(
        title: 'Locked note',
        content: 'body',
        actor: 'x',
      );

      final before = await call('get_note', {'id': note.id});
      expect(_structured(before)['lock'], isNull);

      await deps.lockManager.acquire(noteId: note.id, actor: 'alice');
      final after = await call('get_note', {'id': note.id});
      final lock = _structured(after)['lock']! as Map<String, Object?>;
      expect(lock['holder'], 'alice');
    });

    test('returns not_found for an unknown id', () async {
      final result = await call('get_note', {'id': 'missing'});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], ErrorCode.notFound.wire);
    });
  });

  group('search_notes', () {
    test('returns a hit with a <mark> snippet', () async {
      await deps.noteWriteService.create(
        title: 'Finance',
        content: 'quarterly budget review',
        actor: 'x',
      );

      final result = await call('search_notes', {'query': 'budget'});
      final items = _structured(result)['items']! as List<Object?>;
      expect(items, hasLength(1));
      final hit = items.single! as Map<String, Object?>;
      expect(hit['snippet'], contains('<mark>budget</mark>'));
    });

    test('rejects a blank query as validation_failed', () async {
      final result = await call('search_notes', {'query': '   '});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('rejects invalid FTS syntax as validation_failed', () async {
      final result = await call('search_notes', {'query': '"unterminated'});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });
  });

  group('create_note', () {
    test('creates the note and returns the full record', () async {
      final result = await call('create_note', {
        'title': 'Inbox',
        'content': 'first line',
      });
      final s = _structured(result);
      expect(s['id'], isNotEmpty);
      expect(s['title'], 'Inbox');
      expect(s['content'], 'first line');
      expect(s['version'], 1);
    });

    test('rejects an empty title as validation_failed', () async {
      final result = await call('create_note', {'title': '   '});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('broadcasts a created event with the principal actor', () async {
      final received = <WsMessage>[];
      deps.broadcaster
        ..register('c1').listen(received.add)
        ..subscribeWildcard('c1');

      await call('create_note', {'title': 'Broadcast check'});
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      final event = received.single as ChangedEvent;
      expect(event.action, ChangeAction.created);
      expect(event.by, fullAccess.actor);
    });
  });

  group('update_note', () {
    test('succeeds and returns the new version', () async {
      final note = await deps.noteWriteService.create(
        title: 'Draft',
        content: 'v1',
        actor: 'x',
      );

      final result = await call('update_note', {
        'id': note.id,
        'version': note.version,
        'content': 'v2',
      });
      final s = _structured(result);
      expect(s['version'], 2);
      expect(s['content'], 'v2');
      expect(s['title'], 'Draft');
    });

    test(
      'returns version_conflict with current state on stale version',
      () async {
        final note = await deps.noteWriteService.create(
          title: 'Draft',
          content: 'v1',
          actor: 'x',
        );
        await deps.noteWriteService.update(
          id: note.id,
          title: 'Draft',
          content: 'v2',
          ifMatch: note.version,
          actor: 'x',
        );

        final result = await call('update_note', {
          'id': note.id,
          'version': note.version,
          'content': 'v3',
        });
        expect(result['isError'], isTrue);
        final s = _structured(result);
        expect(s['error'], ErrorCode.versionConflict.wire);
        expect(s['current_version'], 2);
        expect(s['current_content'], 'v2');
      },
    );

    test('rejects an update with neither title nor content', () async {
      final note = await deps.noteWriteService.create(
        title: 'Draft',
        content: 'v1',
        actor: 'x',
      );

      final result = await call('update_note', {
        'id': note.id,
        'version': note.version,
      });
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test(
      'returns locked with holder when another actor holds the lock',
      () async {
        final note = await deps.noteWriteService.create(
          title: 'Draft',
          content: 'v1',
          actor: 'x',
        );
        await deps.lockManager.acquire(noteId: note.id, actor: 'alice');

        final result = await call(
          'update_note',
          {
            'id': note.id,
            'version': note.version,
            'content': 'v2',
          },
          bob,
        );
        expect(result['isError'], isTrue);
        final s = _structured(result);
        expect(s['error'], ErrorCode.locked.wire);
        expect(s['holder'], 'alice');
      },
    );

    test('broadcasts an updated event with the principal actor', () async {
      final note = await deps.noteWriteService.create(
        title: 'Draft',
        content: 'v1',
        actor: 'x',
      );
      final received = <WsMessage>[];
      deps.broadcaster
        ..register('c1').listen(received.add)
        ..subscribeWildcard('c1');

      await call('update_note', {
        'id': note.id,
        'version': note.version,
        'content': 'v2',
      });
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      final event = received.single as ChangedEvent;
      expect(event.action, ChangeAction.updated);
      expect(event.by, fullAccess.actor);
    });
  });

  group('delete_note', () {
    test('deletes an unlocked note and broadcasts', () async {
      final note = await deps.noteWriteService.create(
        title: 'Doomed',
        content: '',
        actor: 'x',
      );
      final received = <WsMessage>[];
      deps.broadcaster
        ..register('c1').listen(received.add)
        ..subscribeWildcard('c1');

      final result = await call('delete_note', {'id': note.id});
      await Future<void>.delayed(Duration.zero);

      expect(_structured(result), {'id': note.id, 'deleted': true});
      expect(received, hasLength(1));
      final event = received.single as ChangedEvent;
      expect(event.action, ChangeAction.deleted);
      expect(event.by, fullAccess.actor);
    });

    test(
      'returns locked with holder when another actor holds the lock',
      () async {
        final note = await deps.noteWriteService.create(
          title: 'Doomed',
          content: '',
          actor: 'x',
        );
        await deps.lockManager.acquire(noteId: note.id, actor: 'alice');

        final result = await call(
          'delete_note',
          {
            'id': note.id,
          },
          bob,
        );
        expect(result['isError'], isTrue);
        final s = _structured(result);
        expect(s['error'], ErrorCode.locked.wire);
        expect(s['holder'], 'alice');
      },
    );
  });

  group('append_to_note', () {
    test('separates with a newline and bumps the version', () async {
      final note = await deps.noteWriteService.create(
        title: 'Log',
        content: 'line one',
        actor: 'x',
      );

      final result = await call('append_to_note', {
        'id': note.id,
        'text': 'line two',
      });
      final s = _structured(result);
      expect(s['version'], note.version + 1);

      final reread = await deps.storage.read(note.id);
      expect(reread.content, 'line one\nline two');
    });

    test('appends without a separator to an empty note', () async {
      final note = await deps.noteWriteService.create(
        title: 'Log',
        content: '',
        actor: 'x',
      );

      await call('append_to_note', {'id': note.id, 'text': 'first'});

      final reread = await deps.storage.read(note.id);
      expect(reread.content, 'first');
    });

    test('does not double an existing trailing newline', () async {
      final note = await deps.noteWriteService.create(
        title: 'Log',
        content: 'line one\n',
        actor: 'x',
      );

      await call('append_to_note', {'id': note.id, 'text': 'line two'});

      final reread = await deps.storage.read(note.id);
      expect(reread.content, 'line one\nline two');
    });

    test('rejects empty text as validation_failed', () async {
      final note = await deps.noteWriteService.create(
        title: 'Log',
        content: 'line one',
        actor: 'x',
      );

      final result = await call('append_to_note', {
        'id': note.id,
        'text': '',
      });
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test(
      'returns locked with holder when another actor holds the lock',
      () async {
        final note = await deps.noteWriteService.create(
          title: 'Log',
          content: 'line one',
          actor: 'x',
        );
        await deps.lockManager.acquire(noteId: note.id, actor: 'alice');

        final result = await call(
          'append_to_note',
          {
            'id': note.id,
            'text': 'line two',
          },
          bob,
        );
        expect(result['isError'], isTrue);
        final s = _structured(result);
        expect(s['error'], ErrorCode.locked.wire);
        expect(s['holder'], 'alice');
      },
    );

    test('two concurrent appends both land', () async {
      final note = await deps.noteWriteService.create(
        title: 'Log',
        content: 'start',
        actor: 'x',
      );

      final results = await Future.wait([
        call('append_to_note', {'id': note.id, 'text': 'alpha'}),
        call('append_to_note', {'id': note.id, 'text': 'beta'}),
      ]);

      for (final result in results) {
        expect(result['isError'], isNull);
      }
      final reread = await deps.storage.read(note.id);
      expect(reread.content, contains('alpha'));
      expect(reread.content, contains('beta'));
      expect(reread.version, 3);
    });
  });

  group('scope gating', () {
    test('a read-only principal cannot call a write tool', () async {
      final result = await call('create_note', {'title': 'nope'}, readOnly);
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], kErrorInsufficientScope);
    });

    test('a write-only principal cannot call a read tool', () async {
      final result = await call('list_notes', {}, writeOnly);
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], kErrorInsufficientScope);
    });

    test('the static-key principal passes both scope checks', () async {
      final readResult = await call('list_notes', {});
      expect(readResult['isError'], isNull);

      final writeResult = await call('create_note', {'title': 'ok'});
      expect(writeResult['isError'], isNull);
    });
  });

  group('tools/list catalog', () {
    test('has exactly the seven note tools with object schemas', () {
      final names = registry.tools.map((t) => t.name).toSet();
      expect(names, {
        'list_notes',
        'get_note',
        'create_note',
        'update_note',
        'append_to_note',
        'delete_note',
        'search_notes',
      });
      for (final tool in registry.tools) {
        expect(tool.inputSchema['type'], 'object');
      }
    });

    test('update_note declares id and version as required', () {
      final tool = registry.tools.firstWhere((t) => t.name == 'update_note');
      expect(tool.inputSchema['required'], ['id', 'version']);
    });

    test('unknown tool name throws McpUnknownToolException', () async {
      await expectLater(
        call('no_such_tool', {}),
        throwsA(isA<McpUnknownToolException>()),
      );
    });
  });
}
