import 'dart:async';
import 'dart:io';

import 'package:server/src/app_deps.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/invite_store.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tool_results.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/consent_throttle.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';
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

/// A well-formed note file, used to plant a canary outside `content/` when
/// proving a path-traversal id cannot reach it — if the id check were
/// missing, `storage.read`/`update`/`delete` would happily follow `..` to
/// this file since `Storage` builds paths by string interpolation.
const String _canaryNoteFile = '---\n'
    'id: canary\n'
    'title: Canary\n'
    'version: 1\n'
    'created_at: 2024-01-01T00:00:00.000Z\n'
    'updated_at: 2024-01-01T00:00:00.000Z\n'
    '---\n'
    'top secret';

/// Plants [_canaryNoteFile] at `<tmp>/x.md`, one level above `content/`.
/// The OS only resolves a `..` path segment through a directory that
/// exists, so this also creates `content/` first — mirroring a server
/// that already has at least one note on disk.
File _plantCanary(Directory tmp) {
  Directory('${tmp.path}/content').createSync(recursive: true);
  return File('${tmp.path}/x.md')..writeAsStringSync(_canaryNoteFile);
}

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

/// A [Storage] whose [update] reports a version conflict for the first
/// [failCount] calls regardless of the caller's `ifMatch`, then behaves
/// normally — used to force append_to_note's retry loop to exhaust
/// without racing real concurrent writers.
class _FlakyStorage extends Storage {
  _FlakyStorage({
    required super.contentDir,
    required this.failCount,
    this.onConflict,
  });

  final int failCount;

  /// Invoked synchronously each time [update] reports a synthetic
  /// conflict — lets a test simulate another actor acting in the gap
  /// between one failed attempt and the caller's next retry.
  final void Function()? onConflict;

  int _calls = 0;

  @override
  Future<StoredNote> update({
    required NoteId id,
    required String title,
    required String content,
    required int ifMatch,
    String? path,
    Map<String, Object?>? properties,
  }) async {
    if (_calls < failCount) {
      _calls++;
      final current = await read(id);
      onConflict?.call();
      throw VersionConflictException(
        current: current,
        suppliedIfMatch: ifMatch,
      );
    }
    return super.update(
      id: id,
      title: title,
      content: content,
      ifMatch: ifMatch,
      path: path,
      properties: properties,
    );
  }
}

/// Builds a standalone [AppDeps] backed by [_FlakyStorage], rooted at a
/// fresh temp directory the caller is responsible for cleaning up.
Future<AppDeps> _bootstrapFlaky(
  Directory tmp, {
  required int failCount,
  void Function()? onConflict,
}) async {
  final storage = _FlakyStorage(
    contentDir: Directory('${tmp.path}/content'),
    failCount: failCount,
    onConflict: onConflict,
  );
  return AppDeps(
    storage: storage,
    metaIndex: MetaIndex(),
    searchIndex: await SearchIndex.open(
      dbFile: File('${tmp.path}/search.db'),
      storage: storage,
    ),
    inviteStore: InviteStore(inviteDir: Directory('${tmp.path}/invites')),
    clientStore: ClientStore(dir: Directory('${tmp.path}/oauth/clients')),
    codeStore: CodeStore(dir: Directory('${tmp.path}/oauth/codes')),
    tokenStore: TokenStore(dir: Directory('${tmp.path}/oauth/tokens')),
    consentThrottle: ConsentThrottle(),
    lockManager: LockManager(),
    broadcaster: Broadcaster(),
    presence: PresenceTracker(),
    clock: const Clock(),
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

    test('sort: updated_desc returns newest-updated notes first', () async {
      final a = await deps.noteWriteService.create(
        title: 'a',
        content: '',
        actor: 'x',
      );
      await deps.noteWriteService.create(title: 'b', content: '', actor: 'x');
      await deps.noteWriteService.update(
        id: a.id,
        title: 'a',
        content: 'edited',
        ifMatch: 1,
        actor: 'x',
      );

      final result = await call('list_notes', {'sort': 'updated_desc'});
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.first['id'], a.id);
    });

    test('rejects an unsupported sort value', () async {
      final result = await call('list_notes', {'sort': 'bogus'});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], kErrorValidationFailed);
    });

    test('items include path', () async {
      await deps.noteWriteService.create(
        title: 'Nested',
        content: '',
        actor: 'x',
        path: 'Projects/Alpha',
      );

      final result = await call('list_notes', {});
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.single['path'], 'Projects/Alpha');
    });

    test('path filter narrows results to a folder', () async {
      await deps.noteWriteService.create(
        title: 'In folder',
        content: '',
        actor: 'x',
        path: 'Projects/Alpha',
      );
      await deps.noteWriteService.create(
        title: 'At root',
        content: '',
        actor: 'x',
      );

      final result = await call('list_notes', {'path': 'Projects/Alpha'});
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.map((i) => i['title']), ['In folder']);
    });

    test('tag filter narrows results to notes carrying the tag', () async {
      await deps.noteWriteService.create(
        title: 'Tagged',
        content: '#urgent',
        actor: 'x',
      );
      await deps.noteWriteService.create(
        title: 'Untagged',
        content: '',
        actor: 'x',
      );

      final result = await call('list_notes', {'tag': 'urgent'});
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.map((i) => i['title']), ['Tagged']);
    });

    test('title filter narrows results to the exact title', () async {
      await deps.noteWriteService.create(
        title: 'Project Alpha',
        content: '',
        actor: 'x',
      );
      await deps.noteWriteService.create(
        title: 'Project Beta',
        content: '',
        actor: 'x',
      );

      final result = await call('list_notes', {'title': 'Project Alpha'});
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.map((i) => i['title']), ['Project Alpha']);
    });

    test('title filter matching is case- and NFC-insensitive', () async {
      await deps.noteWriteService.create(
        title: 'caf${String.fromCharCode(0x00e9)}',
        content: '',
        actor: 'x',
      );

      final decomposedQuery = 'CAF${String.fromCharCodes([0x65, 0x0301])}';
      final result = await call('list_notes', {'title': decomposedQuery});
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items, hasLength(1));
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

    test(
      'rejects a path-traversal id as not_found without reading the file',
      () async {
        _plantCanary(tmp);

        final result = await call('get_note', {'id': '../x'});

        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], ErrorCode.notFound.wire);
      },
    );
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

    test(
      'rejects a limit above 100 as an invalid param, matching GET /search',
      () async {
        await expectLater(
          call('search_notes', {'query': 'budget', 'limit': 101}),
          throwsA(isA<McpInvalidParamsException>()),
        );
      },
    );

    test('hits include path', () async {
      await deps.noteWriteService.create(
        title: 'Finance',
        content: 'quarterly budget review',
        actor: 'x',
        path: 'Projects/Alpha',
      );

      final result = await call('search_notes', {'query': 'budget'});
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.single['path'], 'Projects/Alpha');
    });

    test('path filter narrows results to a folder', () async {
      await deps.noteWriteService.create(
        title: 'In folder',
        content: 'budget plan',
        actor: 'x',
        path: 'Projects/Alpha',
      );
      await deps.noteWriteService.create(
        title: 'At root',
        content: 'budget plan',
        actor: 'x',
      );

      final result = await call('search_notes', {
        'query': 'budget',
        'path': 'Projects/Alpha',
      });
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.map((i) => i['title']), ['In folder']);
    });

    test('tag filter narrows results to notes carrying the tag', () async {
      await deps.noteWriteService.create(
        title: 'Tagged',
        content: 'budget plan #finance',
        actor: 'x',
      );
      await deps.noteWriteService.create(
        title: 'Untagged',
        content: 'budget plan',
        actor: 'x',
      );

      final result = await call('search_notes', {
        'query': 'budget',
        'tag': 'finance',
      });
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.map((i) => i['title']), ['Tagged']);
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
      expect(s['path'], '');
    });

    test('creates the note under the given path', () async {
      final result = await call('create_note', {
        'title': 'Nested',
        'path': 'Projects/Alpha',
      });
      expect(_structured(result)['path'], 'Projects/Alpha');
    });

    test('rejects an empty title as validation_failed', () async {
      final result = await call('create_note', {'title': '   '});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('a path collision is a path_conflict tool error', () async {
      await deps.noteWriteService.create(
        title: 'Notes',
        content: '',
        actor: 'x',
        path: 'Projects/Alpha',
      );

      final result = await call('create_note', {
        'title': 'Notes',
        'path': 'Projects/Alpha',
      });
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], kErrorPathConflict);
    });

    test(
        'a path-traversal path is a validation_failed tool error, not '
        'a crash', () async {
      final result = await call('create_note', {
        'title': 'Escape',
        'path': '../../../tmp/escaped',
      });
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

    test(
      'omits current_content from version_conflict for a write-only '
      'principal',
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

        final args = {
          'id': note.id,
          'version': note.version,
          'content': 'v3',
        };
        final result = await call('update_note', args, writeOnly);
        expect(result['isError'], isTrue);
        final s = _structured(result);
        expect(s['error'], ErrorCode.versionConflict.wire);
        expect(s['current_version'], 2);
        expect(s.containsKey('current_content'), isFalse);
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

    test('rejects a blank supplied title as validation_failed', () async {
      final note = await deps.noteWriteService.create(
        title: 'Draft',
        content: 'v1',
        actor: 'x',
      );

      final result = await call('update_note', {
        'id': note.id,
        'version': note.version,
        'title': '   ',
      });
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('a path-only change moves the note and broadcasts moved', () async {
      final note = await deps.noteWriteService.create(
        title: 'Draft',
        content: 'v1',
        actor: 'x',
      );
      final received = <WsMessage>[];
      deps.broadcaster
        ..register('c1').listen(received.add)
        ..subscribeWildcard('c1');

      final result = await call('update_note', {
        'id': note.id,
        'version': note.version,
        'path': 'Projects/Alpha',
      });
      final s = _structured(result);
      expect(s['path'], 'Projects/Alpha');
      expect(s['content'], 'v1');
      expect(s['version'], 2);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect((received.single as ChangedEvent).action, ChangeAction.moved);
    });

    test(
      'a colliding target path is a path_conflict tool error',
      () async {
        await deps.noteWriteService.create(
          title: 'Existing',
          content: '',
          actor: 'x',
          path: 'Projects/Alpha',
        );
        final note = await deps.noteWriteService.create(
          title: 'Existing',
          content: '',
          actor: 'x',
        );

        final result = await call('update_note', {
          'id': note.id,
          'version': note.version,
          'path': 'Projects/Alpha',
        });
        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], kErrorPathConflict);
      },
    );

    test(
      'a path-traversal path is a validation_failed tool error, not a crash',
      () async {
        final canary = _plantCanary(tmp);
        final note = await deps.noteWriteService.create(
          title: 'Note',
          content: '',
          actor: 'x',
        );

        final result = await call('update_note', {
          'id': note.id,
          'version': note.version,
          'path': '../../../tmp/escaped',
        });

        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], 'validation_failed');
        expect(canary.readAsStringSync(), _canaryNoteFile);
      },
    );

    test(
      'rejects a path-traversal id as not_found without writing the file',
      () async {
        final canary = _plantCanary(tmp);

        final result = await call('update_note', {
          'id': '../x',
          'version': 1,
          'content': 'pwned',
        });

        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], ErrorCode.notFound.wire);
        expect(canary.readAsStringSync(), _canaryNoteFile);
      },
    );

    test(
      'returns locked with holder when another actor holds the lock',
      () async {
        final note = await deps.noteWriteService.create(
          title: 'Draft',
          content: 'v1',
          actor: 'x',
        );
        await deps.lockManager.acquire(noteId: note.id, actor: 'alice');

        final args = {
          'id': note.id,
          'version': note.version,
          'content': 'v2',
        };
        final result = await call('update_note', args, bob);
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
      'rejects a path-traversal id as not_found without deleting the file',
      () async {
        final canary = _plantCanary(tmp);

        final result = await call('delete_note', {'id': '../x'});

        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], ErrorCode.notFound.wire);
        expect(canary.existsSync(), isTrue);
      },
    );

    test(
      'returns locked with holder when another actor holds the lock',
      () async {
        final note = await deps.noteWriteService.create(
          title: 'Doomed',
          content: '',
          actor: 'x',
        );
        await deps.lockManager.acquire(noteId: note.id, actor: 'alice');

        final result = await call('delete_note', {'id': note.id}, bob);
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

      final result = await call('append_to_note', {'id': note.id, 'text': ''});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('rejects whitespace-only text as validation_failed', () async {
      final note = await deps.noteWriteService.create(
        title: 'Log',
        content: 'line one',
        actor: 'x',
      );

      final result = await call('append_to_note', {
        'id': note.id,
        'text': '   ',
      });
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test(
      'rejects a path-traversal id as not_found without writing the file',
      () async {
        final canary = _plantCanary(tmp);

        final result = await call('append_to_note', {
          'id': '../x',
          'text': 'pwned',
        });

        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], ErrorCode.notFound.wire);
        expect(canary.readAsStringSync(), _canaryNoteFile);
      },
    );

    test(
      'returns locked with holder when another actor holds the lock',
      () async {
        final note = await deps.noteWriteService.create(
          title: 'Log',
          content: 'line one',
          actor: 'x',
        );
        await deps.lockManager.acquire(noteId: note.id, actor: 'alice');

        final args = {'id': note.id, 'text': 'line two'};
        final result = await call('append_to_note', args, bob);
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

    test(
      'returns version_conflict after exhausting all retries',
      () async {
        final flakyTmp = _tempDir();
        addTearDown(() {
          if (flakyTmp.existsSync()) flakyTmp.deleteSync(recursive: true);
        });
        final flakyDeps = await _bootstrapFlaky(
          flakyTmp,
          failCount: kMcpAppendMaxRetries + 1,
        );
        addTearDown(flakyDeps.close);
        final note = await flakyDeps.noteWriteService.create(
          title: 'Log',
          content: 'line one',
          actor: 'x',
        );
        final flakyRegistry = McpToolRegistry.forDeps(flakyDeps);

        final result = await flakyRegistry.call(
          'append_to_note',
          {'id': note.id, 'text': 'line two'},
          fullAccess,
        );

        expect(result['isError'], isTrue);
        final s = _structured(result);
        expect(s['error'], ErrorCode.versionConflict.wire);
        expect(s['current_version'], note.version);
        expect(s['current_content'], note.content);
      },
    );

    test(
      'returns locked if another actor acquires the lock between retries',
      () async {
        final flakyTmp = _tempDir();
        addTearDown(() {
          if (flakyTmp.existsSync()) flakyTmp.deleteSync(recursive: true);
        });
        late LockManager lockManager;
        late String noteId;
        final flakyDeps = await _bootstrapFlaky(
          flakyTmp,
          failCount: 1,
          onConflict: () => lockManager.acquire(noteId: noteId, actor: 'alice'),
        );
        lockManager = flakyDeps.lockManager;
        addTearDown(flakyDeps.close);
        final note = await flakyDeps.noteWriteService.create(
          title: 'Log',
          content: 'line one',
          actor: 'x',
        );
        noteId = note.id;
        final flakyRegistry = McpToolRegistry.forDeps(flakyDeps);

        final result = await flakyRegistry.call(
          'append_to_note',
          {'id': note.id, 'text': 'line two'},
          fullAccess,
        );

        expect(result['isError'], isTrue);
        final s = _structured(result);
        expect(s['error'], ErrorCode.locked.wire);
        expect(s['holder'], 'alice');
      },
    );
  });

  group('move_note', () {
    test('relocates the note and returns the full record', () async {
      final note = await deps.noteWriteService.create(
        title: 'Draft',
        content: 'body',
        actor: 'x',
      );

      final result = await call('move_note', {
        'id': note.id,
        'version': note.version,
        'path': 'Projects/Alpha',
      });
      final s = _structured(result);
      expect(s['path'], 'Projects/Alpha');
      expect(s['title'], 'Draft');
      expect(s['content'], 'body');
      expect(s['version'], 2);
    });

    test('broadcasts a moved event', () async {
      final note = await deps.noteWriteService.create(
        title: 'Draft',
        content: '',
        actor: 'x',
      );
      final received = <WsMessage>[];
      deps.broadcaster
        ..register('c1').listen(received.add)
        ..subscribeWildcard('c1');

      await call('move_note', {
        'id': note.id,
        'version': note.version,
        'path': 'Projects/Alpha',
      });
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      final event = received.single as ChangedEvent;
      expect(event.action, ChangeAction.moved);
      expect(event.by, fullAccess.actor);
    });

    test('returns version_conflict with current state on stale version',
        () async {
      final note = await deps.noteWriteService.create(
        title: 'Draft',
        content: 'body',
        actor: 'x',
      );
      await deps.noteWriteService.update(
        id: note.id,
        title: 'Draft',
        content: 'edited',
        ifMatch: note.version,
        actor: 'x',
      );

      final result = await call('move_note', {
        'id': note.id,
        'version': note.version,
        'path': 'Projects/Alpha',
      });
      expect(result['isError'], isTrue);
      final s = _structured(result);
      expect(s['error'], ErrorCode.versionConflict.wire);
      expect(s['current_version'], 2);
    });

    test('a colliding target path is a path_conflict tool error', () async {
      await deps.noteWriteService.create(
        title: 'Existing',
        content: '',
        actor: 'x',
        path: 'Projects/Alpha',
      );
      final note = await deps.noteWriteService.create(
        title: 'Existing',
        content: '',
        actor: 'x',
      );

      final result = await call('move_note', {
        'id': note.id,
        'version': note.version,
        'path': 'Projects/Alpha',
      });
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], kErrorPathConflict);
    });

    test(
      'a path-traversal path is a validation_failed tool error, not a crash',
      () async {
        final canary = _plantCanary(tmp);
        final note = await deps.noteWriteService.create(
          title: 'Note',
          content: '',
          actor: 'x',
        );

        final result = await call('move_note', {
          'id': note.id,
          'version': note.version,
          'path': '../../../tmp/escaped',
        });

        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], 'validation_failed');
        expect(canary.readAsStringSync(), _canaryNoteFile);
      },
    );

    test(
      'returns locked with holder when another actor holds the lock',
      () async {
        final note = await deps.noteWriteService.create(
          title: 'Draft',
          content: '',
          actor: 'x',
        );
        await deps.lockManager.acquire(noteId: note.id, actor: 'alice');

        final result = await call(
          'move_note',
          {
            'id': note.id,
            'version': note.version,
            'path': 'Projects/Alpha',
          },
          bob,
        );
        expect(result['isError'], isTrue);
        final s = _structured(result);
        expect(s['error'], ErrorCode.locked.wire);
        expect(s['holder'], 'alice');
      },
    );

    test(
      'rejects a path-traversal id as not_found without writing the file',
      () async {
        final canary = _plantCanary(tmp);

        final result = await call('move_note', {
          'id': '../x',
          'version': 1,
          'path': 'elsewhere',
        });

        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], ErrorCode.notFound.wire);
        expect(canary.readAsStringSync(), _canaryNoteFile);
      },
    );
  });

  group('get_backlinks', () {
    test('lists every note whose content links to the given note', () async {
      final a = await deps.noteWriteService.create(
        title: 'Alpha',
        content: '',
        actor: 'x',
      );
      final b = await deps.noteWriteService.create(
        title: 'Beta',
        content: 'refers to [[Alpha]]',
        actor: 'x',
      );

      final result = await call('get_backlinks', {'id': a.id});
      final items = (_structured(result)['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.single['id'], b.id);
      expect(items.single['title'], 'Beta');
      expect((items.single['snippet']! as String).contains('Alpha'), isTrue);
    });

    test('a note with no backlinks returns an empty items list', () async {
      final a = await deps.noteWriteService.create(
        title: 'Lonely',
        content: '',
        actor: 'x',
      );

      final result = await call('get_backlinks', {'id': a.id});
      expect(_structured(result)['items'], isEmpty);
    });

    test('returns not_found for an unknown id', () async {
      final result = await call('get_backlinks', {'id': 'missing'});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], ErrorCode.notFound.wire);
    });

    test(
      'rejects a path-traversal id as not_found without reading the file',
      () async {
        _plantCanary(tmp);

        final result = await call('get_backlinks', {'id': '../x'});

        expect(result['isError'], isTrue);
        expect(_structured(result)['error'], ErrorCode.notFound.wire);
      },
    );
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

  group('create_folder', () {
    test('creates a new folder and returns structuredContent', () async {
      final result = await call('create_folder', {'path': 'Ideas'});
      expect(result['isError'], isNot(true));
      expect(_structured(result), {'path': 'Ideas', 'note_count': 0});
    });

    test('calling twice succeeds both times with the same structuredContent',
        () async {
      final first = await call('create_folder', {'path': 'Ideas'});
      final second = await call('create_folder', {'path': 'Ideas'});
      expect(_structured(first), _structured(second));
      expect(second['isError'], isNot(true));
    });

    test('an empty path is a validation_failed error', () async {
      final result = await call('create_folder', {'path': ''});
      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test(
        'calling create_folder on an existing note-backed folder does not '
        'register it as a marker-tracked empty folder', () async {
      await deps.noteWriteService.create(
        title: 'A',
        content: '',
        actor: 'tester',
        path: 'Projects/Alpha',
      );

      final result = await call('create_folder', {'path': 'Projects/Alpha'});

      expect(_structured(result), {'path': 'Projects/Alpha', 'note_count': 1});
      expect(deps.metaIndex.emptyFolders, isNot(contains('Projects/Alpha')));
    });
  });

  group('request_upload / finalize_upload', () {
    test('request_upload returns a token, upload_url, and expires_at',
        () async {
      final result = await call('request_upload', {
        'path': 'Ideas',
        'filename': 'photo.png',
      });

      expect(result['isError'], isNot(true));
      final structured = _structured(result);
      expect(structured['token'], isA<String>());
      expect(
        structured['upload_url'],
        '/notes/file-uploads/${structured['token']}',
      );
      expect(structured['expires_at'], isA<String>());
    });

    test('a declared size_bytes over the configured limit is rejected',
        () async {
      final result = await call('request_upload', {
        'path': 'Ideas',
        'filename': 'big.bin',
        'size_bytes': Config.defaultMaxUploadSizeBytes + 1,
      });

      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'payload_too_large');
    });

    test(
        'finalize_upload places a completed upload into the vault and it '
        'is retrievable', () async {
      final requested = _structured(
        await call('request_upload', {
          'path': 'Ideas',
          'filename': 'photo.png',
        }),
      );
      final token = requested['token']! as String;
      await deps.uploadSessions.complete(
        token: token,
        bytes: Stream.value([1, 2, 3]),
        contentType: 'image/png',
      );

      final result = await call('finalize_upload', {'token': token});

      expect(result['isError'], isNot(true));
      expect(_structured(result), {
        'path': 'Ideas',
        'filename': 'photo.png',
        'size': 3,
        'content_type': 'image/png',
      });
      expect(
        File('${tmp.path}/content/Ideas/photo.png').readAsBytesSync(),
        [1, 2, 3],
      );
      // Discoverable without a restart, the same as a direct upload —
      // regression coverage for finalize_upload forgetting to tell
      // Storage's file index about the write.
      expect(
        deps.storage.filesIn('Ideas').map((f) => f.relativePath),
        ['Ideas/photo.png'],
      );
    });

    test('finalize_upload before the PUT has completed is validation_failed',
        () async {
      final requested = _structured(
        await call('request_upload', {
          'path': 'Ideas',
          'filename': 'photo.png',
        }),
      );

      final result = await call(
        'finalize_upload',
        {'token': requested['token']! as String},
      );

      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('finalize_upload with an unknown token is validation_failed',
        () async {
      final result = await call('finalize_upload', {'token': 'nope'});

      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'validation_failed');
    });

    test('a collision at finalize time is a path_conflict tool error',
        () async {
      final requested = _structured(
        await call('request_upload', {
          'path': 'Ideas',
          'filename': 'photo.png',
        }),
      );
      final token = requested['token']! as String;
      await deps.uploadSessions
          .complete(token: token, bytes: Stream.value([1]));
      // Claim the target after the slot was reserved but before finalize.
      await deps.fileStore.write(
        path: 'Ideas',
        filename: 'photo.png',
        bytes: Stream.value([9]),
        maxBytes: Config.defaultMaxUploadSizeBytes,
      );

      final result = await call('finalize_upload', {'token': token});

      expect(result['isError'], isTrue);
      expect(_structured(result)['error'], 'path_conflict');
    });
  });

  group('tools/list catalog', () {
    test('has exactly the twelve note tools with object schemas', () {
      final names = registry.tools.map((t) => t.name).toSet();
      expect(names, {
        'list_notes',
        'get_note',
        'create_note',
        'update_note',
        'append_to_note',
        'delete_note',
        'search_notes',
        'move_note',
        'get_backlinks',
        'create_folder',
        'request_upload',
        'finalize_upload',
      });
      for (final tool in registry.tools) {
        expect(tool.inputSchema['type'], 'object');
      }
    });

    test('create_folder declares path as required', () {
      final tool = registry.tools.firstWhere((t) => t.name == 'create_folder');
      expect(tool.inputSchema['required'], ['path']);
    });

    test('request_upload declares path and filename as required', () {
      final tool = registry.tools.firstWhere((t) => t.name == 'request_upload');
      expect(tool.inputSchema['required'], ['path', 'filename']);
    });

    test('finalize_upload declares token as required', () {
      final tool =
          registry.tools.firstWhere((t) => t.name == 'finalize_upload');
      expect(tool.inputSchema['required'], ['token']);
    });

    test('update_note declares id and version as required', () {
      final tool = registry.tools.firstWhere((t) => t.name == 'update_note');
      expect(tool.inputSchema['required'], ['id', 'version']);
    });

    test('move_note declares id, version, and path as required', () {
      final tool = registry.tools.firstWhere((t) => t.name == 'move_note');
      expect(tool.inputSchema['required'], ['id', 'version', 'path']);
    });

    test('get_backlinks declares id as required', () {
      final tool = registry.tools.firstWhere((t) => t.name == 'get_backlinks');
      expect(tool.inputSchema['required'], ['id']);
    });

    test('list_notes/create_note/search_notes declare path and tag params', () {
      for (final name in ['list_notes', 'search_notes']) {
        final tool = registry.tools.firstWhere((t) => t.name == name);
        final props = tool.inputSchema['properties']! as Map<String, Object?>;
        expect(props.containsKey('path'), isTrue, reason: name);
        expect(props.containsKey('tag'), isTrue, reason: name);
      }
      final createProps = registry.tools
          .firstWhere((t) => t.name == 'create_note')
          .inputSchema['properties']! as Map<String, Object?>;
      expect(createProps.containsKey('path'), isTrue);
    });

    test('list_notes declares a title param', () {
      final props = registry.tools
          .firstWhere((t) => t.name == 'list_notes')
          .inputSchema['properties']! as Map<String, Object?>;
      expect(props.containsKey('title'), isTrue);
    });

    test('unknown tool name throws McpUnknownToolException', () async {
      await expectLater(
        call('no_such_tool', {}),
        throwsA(isA<McpUnknownToolException>()),
      );
    });

    test('every tool declares a non-empty title annotation', () {
      for (final tool in registry.tools) {
        expect(tool.annotations['title'], isA<String>());
        expect(tool.annotations['title'], isNotEmpty);
      }
    });

    test('read-only tools are marked readOnlyHint with no side effects', () {
      for (final name in ['list_notes', 'get_note', 'search_notes']) {
        final tool = registry.tools.firstWhere((t) => t.name == name);
        expect(tool.annotations['readOnlyHint'], isTrue, reason: name);
        expect(tool.annotations['destructiveHint'], isFalse, reason: name);
        expect(tool.annotations['openWorldHint'], isFalse, reason: name);
      }
    });

    test('delete_note is destructive and idempotent', () {
      final tool = registry.tools.firstWhere((t) => t.name == 'delete_note');
      expect(tool.annotations['readOnlyHint'], isFalse);
      expect(tool.annotations['destructiveHint'], isTrue);
      expect(tool.annotations['idempotentHint'], isTrue);
    });

    test(
        'create_note and append_to_note are non-destructive and '
        'non-idempotent', () {
      for (final name in ['create_note', 'append_to_note']) {
        final tool = registry.tools.firstWhere((t) => t.name == name);
        expect(tool.annotations['destructiveHint'], isFalse, reason: name);
        expect(tool.annotations['idempotentHint'], isFalse, reason: name);
      }
    });
  });
}
