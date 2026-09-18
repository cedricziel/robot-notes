import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

class _CapturingBroadcaster implements Broadcaster {
  final List<ChangedEvent> changed = [];

  @override
  void emitChanged(ChangedEvent event) => changed.add(event);

  @override
  int get connectionCount => 0;

  @override
  bool isRegistered(String connectionId) => false;

  @override
  Stream<WsMessage> register(String connectionId) => throw UnimplementedError();

  @override
  void subscribe(String connectionId, String noteId) =>
      throw UnimplementedError();

  @override
  void subscribeWildcard(String connectionId) => throw UnimplementedError();

  @override
  void unsubscribe(String connectionId, String noteId) =>
      throw UnimplementedError();

  @override
  Future<void> disconnect(String connectionId) async =>
      throw UnimplementedError();

  @override
  void emitLock(LockEvent event) => throw UnimplementedError();

  @override
  void emitPresence(PresenceEvent event) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-write-svc-db-test-');

class _Stack {
  _Stack(this.storage, this.meta, this.search, this.registry, this.link);
  final Storage storage;
  final MetaIndex meta;
  final SearchIndex search;
  final DatabaseRegistry registry;
  final LinkIndex link;
}

Future<_Stack> _stack(Directory tmp) async {
  final storage = Storage(
    contentDir: Directory('${tmp.path}/content'),
    clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
  );
  final meta = MetaIndex();
  final search = await SearchIndex.open(
    dbFile: File('${tmp.path}/search.db'),
    storage: storage,
  );
  return _Stack(storage, meta, search, DatabaseRegistry(), LinkIndex());
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<StoredNote> makeDatabase(
    NoteWriteService svc, {
    String title = 'Projects',
    String path = 'Projects',
    Map<String, Object?> properties = const {
      'status': {
        'type': 'select',
        'options': ['todo', 'done'],
      },
    },
  }) {
    return svc.storage.create(
      title: title,
      content: '',
      path: path,
      properties: {
        'type': 'database',
        'source': {'folder': path, 'include_subfolders': true},
        'properties': properties,
        'views': [],
      },
    );
  }

  group('NoteWriteService.create with properties', () {
    test(
      'validates properties against a covering database and rejects a bad '
      'option',
      () async {
        final s = await _stack(tmp);
        addTearDown(s.search.close);
        final def = await makeDatabase(
          NoteWriteService(
            storage: s.storage,
            metaIndex: s.meta,
            searchIndex: s.search,
            broadcaster: _CapturingBroadcaster(),
          ),
        );
        s.registry.upsert(def.toSummary(), def.extra);
        final svc = NoteWriteService(
          storage: s.storage,
          metaIndex: s.meta,
          searchIndex: s.search,
          broadcaster: _CapturingBroadcaster(),
          registry: s.registry,
        );

        expect(
          () => svc.create(
            title: 'Task A',
            content: '',
            actor: 'a',
            path: 'Projects',
            properties: {'status': 'not-an-option'},
          ),
          throwsA(isA<PropertyValidationException>()),
        );
      },
    );

    test('accepts a valid property value and stores it', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final def = await makeDatabase(
        NoteWriteService(
          storage: s.storage,
          metaIndex: s.meta,
          searchIndex: s.search,
          broadcaster: _CapturingBroadcaster(),
        ),
      );
      s.registry.upsert(def.toSummary(), def.extra);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );

      final row = await svc.create(
        title: 'Task A',
        content: '',
        actor: 'a',
        path: 'Projects',
        properties: {'status': 'todo'},
      );
      expect(row.extra, {'status': 'todo'});
    });
  });

  group('NoteWriteService.update with properties', () {
    test('validates and rejects, leaving nothing written', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final bare = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
      );
      final def = await makeDatabase(bare);
      s.registry.upsert(def.toSummary(), def.extra);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );
      final row = await svc.create(
        title: 'Task B',
        content: '',
        actor: 'a',
        path: 'Projects',
        properties: {'status': 'todo'},
      );

      await expectLater(
        svc.update(
          id: row.id,
          title: row.title,
          content: row.content,
          ifMatch: row.version,
          actor: 'a',
          properties: {'status': 'bogus'},
        ),
        throwsA(isA<PropertyValidationException>()),
      );

      final reread = await s.storage.read(row.id);
      expect(reread.version, row.version);
      expect(reread.extra, {'status': 'todo'});
    });

    test(
      'rename propagation (an internal rewrite) tolerates a pre-existing '
      'invalid stored value without validating or failing',
      () async {
        final s = await _stack(tmp);
        addTearDown(s.search.close);
        final svc = NoteWriteService(
          storage: s.storage,
          metaIndex: s.meta,
          searchIndex: s.search,
          broadcaster: _CapturingBroadcaster(),
          linkIndex: s.link,
          registry: s.registry,
        );
        final def = await makeDatabase(svc);
        s.registry.upsert(def.toSummary(), def.extra);

        // Hand-write a row with an invalid stored status (bypassing
        // validation, as a hand-edited file would), that also links to a
        // note we're about to rename.
        final row = await s.storage.create(
          title: 'Task C',
          content: '[[Old Title]]',
          path: 'Projects',
          properties: {'status': 'not-a-declared-option'},
        );
        // Simulate this pre-existing row having been indexed by a startup
        // scan (as a real hand-edited file would be), rather than routed
        // through svc.create — which would have (correctly) rejected its
        // invalid `status` value.
        s.link.upsert(row.id, row.content);

        final other = await svc.create(
          title: 'Old Title',
          content: '',
          actor: 'a',
        );

        // Renaming "Old Title" propagates into Task C's body, even though
        // Task C's own stored `status` is invalid for the database.
        await svc.update(
          id: other.id,
          title: 'New Title',
          content: other.content,
          ifMatch: other.version,
          actor: 'a',
        );

        final rereadRow = await s.storage.read(row.id);
        expect(rereadRow.content, '[[New Title]]');
        expect(rereadRow.extra['status'], 'not-a-declared-option');
      },
    );
  });

  group('NoteWriteService.patchProperties', () {
    Future<({NoteWriteService svc, _Stack s, StoredNote row})> setup() async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );
      final def = await makeDatabase(svc);
      s.registry.upsert(def.toSummary(), def.extra);
      final row = await svc.create(
        title: 'Task D',
        content: 'body text',
        actor: 'a',
        path: 'Projects',
        properties: {'status': 'todo'},
      );
      return (svc: svc, s: s, row: row);
    }

    test('set and unset merge, body preserved, returns stored note', () async {
      final ctx = await setup();
      final patched = await ctx.svc.patchProperties(
        id: ctx.row.id,
        set: {'status': 'done'},
        unset: {},
        actor: 'a',
      );
      expect(patched.extra, {'status': 'done'});
      expect(patched.content, 'body text');
      expect(patched.version, ctx.row.version + 1);
    });

    test('rejects empty set/unset, leaving the file untouched', () async {
      final ctx = await setup();
      await expectLater(
        ctx.svc.patchProperties(id: ctx.row.id, set: {}, unset: {}, actor: 'a'),
        throwsA(isA<PropertyValidationException>()),
      );
      final reread = await ctx.s.storage.read(ctx.row.id);
      expect(reread.version, ctx.row.version);
    });

    test('rejects a key present in both set and unset', () async {
      final ctx = await setup();
      await expectLater(
        ctx.svc.patchProperties(
          id: ctx.row.id,
          set: {'status': 'done'},
          unset: {'status'},
          actor: 'a',
        ),
        throwsA(isA<PropertyValidationException>()),
      );
    });

    test('rejects a reserved/built-in key', () async {
      final ctx = await setup();
      await expectLater(
        ctx.svc.patchProperties(
          id: ctx.row.id,
          set: {'title': 'nope'},
          unset: {},
          actor: 'a',
        ),
        throwsA(isA<PropertyValidationException>()),
      );
    });

    test('rejects a schema violation, leaving the file untouched', () async {
      final ctx = await setup();
      await expectLater(
        ctx.svc.patchProperties(
          id: ctx.row.id,
          set: {'status': 'bogus'},
          unset: {},
          actor: 'a',
        ),
        throwsA(isA<PropertyValidationException>()),
      );
      final reread = await ctx.s.storage.read(ctx.row.id);
      expect(reread.extra, {'status': 'todo'});
    });

    test('ignores an editor lock held by another actor', () async {
      final ctx = await setup();
      await ctx.svc.lockManager.acquire(
        noteId: ctx.row.id,
        actor: 'someone-else',
      );
      final patched = await ctx.svc.patchProperties(
        id: ctx.row.id,
        set: {'status': 'done'},
        unset: {},
        actor: 'a',
      );
      expect(patched.extra, {'status': 'done'});
    });

    test('broadcasts changed/updated with the new version', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final bc = _CapturingBroadcaster();
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: bc,
        registry: s.registry,
      );
      final def = await makeDatabase(svc);
      s.registry.upsert(def.toSummary(), def.extra);
      final row = await svc.create(
        title: 'Task E',
        content: '',
        actor: 'a',
        path: 'Projects',
        properties: {'status': 'todo'},
      );
      bc.changed.clear();

      final patched = await svc.patchProperties(
        id: row.id,
        set: {'status': 'done'},
        unset: {},
        actor: 'b',
      );

      expect(bc.changed, hasLength(1));
      expect(bc.changed.single.action, ChangeAction.updated);
      expect(bc.changed.single.version, patched.version);
      expect(bc.changed.single.by, 'b');
    });

    test(
      'concurrency with update(ifMatch) serializes: one version_conflict, '
      'patched key present',
      () async {
        final ctx = await setup();
        final patched = await ctx.svc.patchProperties(
          id: ctx.row.id,
          set: {'status': 'done'},
          unset: {},
          actor: 'a',
        );
        expect(patched.extra['status'], 'done');

        await expectLater(
          ctx.svc.update(
            id: ctx.row.id,
            title: ctx.row.title,
            content: 'new body',
            ifMatch: ctx.row.version,
            actor: 'b',
          ),
          throwsA(isA<VersionConflictException>()),
        );

        final reread = await ctx.s.storage.read(ctx.row.id);
        expect(reread.extra['status'], 'done');
      },
    );
  });

  group('NoteWriteService.delete', () {
    test('removes the note from the registry', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );
      final def = await makeDatabase(svc);
      s.registry.upsert(def.toSummary(), def.extra);
      expect(s.registry.get(def.id), isNotNull);

      await svc.delete(id: def.id, actor: 'a');

      expect(s.registry.get(def.id), isNull);
    });
  });

  group('NoteWriteService.createRow', () {
    test('defaults the path to the folder source', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );
      final def = await makeDatabase(svc);
      s.registry.upsert(def.toSummary(), def.extra);

      final row = await svc.createRow(
        databaseId: def.id,
        title: 'Row One',
        actor: 'a',
        properties: {'status': 'todo'},
      );

      expect(row.path, 'Projects');
    });

    test('rejects a path outside a folder source', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );
      final def = await makeDatabase(svc);
      s.registry.upsert(def.toSummary(), def.extra);

      expect(
        () => svc.createRow(
          databaseId: def.id,
          title: 'Row Two',
          actor: 'a',
          path: 'Somewhere/Else',
          properties: {'status': 'todo'},
        ),
        throwsA(isA<PathOutsideSourceException>()),
      );
    });

    test('adds the source tag for a tag source', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );
      final def = await s.storage.create(
        title: 'Reading List',
        content: '',
        properties: {
          'type': 'database',
          'source': {'tag': 'reading'},
          'properties': <String, Object?>{},
          'views': [],
        },
      );
      s.registry.upsert(def.toSummary(), def.extra);

      final row = await svc.createRow(
        databaseId: def.id,
        title: 'Some Book',
        actor: 'a',
      );

      final reread = await s.storage.read(row.id);
      expect(reread.extra['tags'], ['reading']);
    });

    test('unknown database id throws DatabaseNotFoundException', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );

      expect(
        () => svc.createRow(databaseId: 'nope', title: 'Row', actor: 'a'),
        throwsA(isA<DatabaseNotFoundException>()),
      );
    });
  });

  group('NoteWriteService.createDatabase / updateDatabase', () {
    test('builds and validates the definition extra', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );

      final note = await svc.createDatabase(
        title: 'Projects',
        actor: 'a',
        path: 'Projects',
        source: const DatabaseSource.folder('Projects'),
        properties: {
          'status': const PropertyDefinition(
            type: PropertyType.select,
            options: ['todo', 'done'],
          ),
        },
      );

      expect(note.extra['type'], 'database');
      expect(s.registry.get(note.id), isNotNull);
    });

    test('rejects an invalid definition', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );

      expect(
        () => svc.createDatabase(
          title: 'Projects',
          actor: 'a',
          source: const DatabaseSource.folder('Projects'),
          properties: {
            'status': const PropertyDefinition(type: PropertyType.select),
          },
        ),
        throwsA(isA<DefinitionValidationException>()),
      );
    });

    test('version_conflict on a stale ifMatch', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        registry: s.registry,
      );
      final note = await svc.createDatabase(
        title: 'Projects',
        actor: 'a',
        path: 'Projects',
        source: const DatabaseSource.folder('Projects'),
      );

      expect(
        () => svc.updateDatabase(
          id: note.id,
          ifMatch: note.version + 99,
          actor: 'a',
          content: 'new body',
        ),
        throwsA(isA<VersionConflictException>()),
      );
    });

    test(
      'a body-only update on a definition preserves type/source/properties/'
      'views',
      () async {
        final s = await _stack(tmp);
        addTearDown(s.search.close);
        final svc = NoteWriteService(
          storage: s.storage,
          metaIndex: s.meta,
          searchIndex: s.search,
          broadcaster: _CapturingBroadcaster(),
          registry: s.registry,
        );
        final note = await svc.createDatabase(
          title: 'Projects',
          actor: 'a',
          path: 'Projects',
          source: const DatabaseSource.folder('Projects'),
          properties: {
            'status': const PropertyDefinition(
              type: PropertyType.select,
              options: ['todo', 'done'],
            ),
          },
        );

        final updated = await svc.updateDatabase(
          id: note.id,
          ifMatch: note.version,
          actor: 'a',
          content: 'new body text',
        );

        expect(updated.content, 'new body text');
        expect(updated.extra['type'], 'database');
        expect(updated.extra['properties'], note.extra['properties']);
        expect(updated.extra['source'], note.extra['source']);
        // An empty `views` list round-trips through YAML as `null` (a
        // pre-existing frontmatter.dart limitation, not something this
        // change touches); either is "no views declared".
        expect(updated.extra['views'], anyOf(isNull, isEmpty));
      },
    );
  });
}
