import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
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

  // The orchestrator only ever drives [emitChanged]; the rest of the
  // surface area is irrelevant. Methods we don't expect to be called
  // throw so a wandering reference fails the test loudly.
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

class _ThrowingBroadcaster extends _CapturingBroadcaster {
  @override
  void emitChanged(ChangedEvent event) {
    super.emitChanged(event);
    throw StateError('ws sink down');
  }
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-write-svc-test-');

Future<({Storage storage, MetaIndex meta, SearchIndex search})> _stack(
  Directory tmp,
) async {
  final storage = Storage(
    contentDir: Directory('${tmp.path}/content'),
    clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
  );
  final meta = MetaIndex();
  final search = await SearchIndex.open(
    dbFile: File('${tmp.path}/search.db'),
    storage: storage,
  );
  return (storage: storage, meta: meta, search: search);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('NoteWriteService.create', () {
    test('updates storage, search, meta, and emits created event', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final bc = _CapturingBroadcaster();
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: bc,
      );

      final note = await svc.create(
        title: 'Mars rover diary',
        content: 'sol 42 dust storm',
        actor: 'orbit-bot',
      );

      // Storage round-trip
      final reread = await s.storage.read(note.id);
      expect(reread.title, 'Mars rover diary');
      expect(reread.version, 1);

      // MetaIndex
      expect(s.meta.length, 1);

      // SearchIndex finds it
      final hits = s.search.search('dust');
      expect(hits, hasLength(1));
      expect(hits.first.id, note.id);

      // Broadcast
      expect(bc.changed, hasLength(1));
      final ev = bc.changed.single;
      expect(ev.noteId, note.id);
      expect(ev.action, ChangeAction.created);
      expect(ev.by, 'orbit-bot');
      expect(ev.version, 1);
    });
  });

  group('NoteWriteService.update', () {
    test('updates all three indices and emits updated event', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final bc = _CapturingBroadcaster();
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: bc,
      );

      final initial = await svc.create(
        title: 'First',
        content: 'old body',
        actor: 'a',
      );

      final updated = await svc.update(
        id: initial.id,
        title: 'First (rev)',
        content: 'fresh body about telescopes',
        ifMatch: 1,
        actor: 'b',
      );
      expect(updated.version, 2);

      // SearchIndex finds the new term, not the old.
      final fresh = s.search.search('telescopes');
      expect(fresh, hasLength(1));
      final old = s.search.search('"old body"');
      expect(old, isEmpty);

      // MetaIndex reflects the new version.
      final summary = s.meta.page().items.single;
      expect(summary.version, 2);
      expect(summary.title, 'First (rev)');

      // Broadcast captures both events in order.
      expect(bc.changed, hasLength(2));
      expect(bc.changed[0].action, ChangeAction.created);
      expect(bc.changed[1].action, ChangeAction.updated);
      expect(bc.changed[1].version, 2);
      expect(bc.changed[1].by, 'b');
    });
  });

  group('NoteWriteService.delete', () {
    test('removes from all three indices and emits deleted event', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final bc = _CapturingBroadcaster();
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: bc,
      );

      final note = await svc.create(
        title: 'Doomed',
        content: 'about to be erased',
        actor: 'a',
      );

      final removed = await svc.delete(id: note.id, actor: 'a');
      expect(removed.id, note.id);

      // Storage gone.
      await expectLater(
        s.storage.read(note.id),
        throwsA(isA<NoteNotFoundException>()),
      );

      // MetaIndex empty.
      expect(s.meta.length, 0);

      // SearchIndex empty for the term.
      expect(s.search.search('erased'), isEmpty);

      // Broadcast: created + deleted.
      expect(bc.changed.last.action, ChangeAction.deleted);
      expect(bc.changed.last.version, note.version);
    });
  });

  group('failure semantics', () {
    test('search index update is in-sync with the file write', () async {
      // Sanity: after a successful create, both stores agree on the title.
      // (Search update sits between the file write and the broadcast, so
      // the moment we observe the response, search MUST already see the
      // new note — otherwise a follow-up GET /search would 404.)
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
      );

      final note = await svc.create(
        title: 'Sync check',
        content: 'crater rim ascent',
        actor: 'a',
      );

      // Search and storage now agree.
      final reread = await s.storage.read(note.id);
      expect(reread.title, 'Sync check');
      expect(s.search.search('crater').single.id, note.id);
    });

    test('broadcast failure does not roll back the file write', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final logger = Logger.detached('write-svc-test')..level = Level.ALL;
      final captured = <Level>[];
      final sub = logger.onRecord.listen((r) => captured.add(r.level));
      addTearDown(sub.cancel);

      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _ThrowingBroadcaster(),
        logger: logger,
      );

      // create() must NOT throw, and the file must be on disk afterwards.
      final note = await svc.create(
        title: 'Survives',
        content: 'broadcast death does not undo write',
        actor: 'a',
      );

      final reread = await s.storage.read(note.id);
      expect(reread.title, 'Survives');
      expect(s.search.search('death').single.id, note.id);
      expect(s.meta.length, 1);
      expect(captured, contains(Level.WARNING));
    });
  });
}
