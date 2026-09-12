import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/lock_manager.dart';
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
    Directory.systemTemp.createTempSync('robot-notes-rename-propagation-');

Future<
    ({
      Storage storage,
      MetaIndex meta,
      SearchIndex search,
      LinkIndex links,
      LockManager locks,
    })> _stack(Directory tmp, {Clock clock = const Clock()}) async {
  final storage =
      Storage(contentDir: Directory('${tmp.path}/content'), clock: clock);
  final meta = MetaIndex();
  final search = await SearchIndex.open(
    dbFile: File('${tmp.path}/search.db'),
    storage: storage,
  );
  final links = LinkIndex();
  final locks = LockManager(clock: clock);
  return (
    storage: storage,
    meta: meta,
    search: search,
    links: links,
    locks: locks
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('rename propagation', () {
    test('rewrites [[OldTitle]] in every referencing note on rename', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      addTearDown(s.locks.close);
      final bc = _CapturingBroadcaster();
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: bc,
        linkIndex: s.links,
        lockManager: s.locks,
      );

      final a = await svc.create(title: 'Old Name', content: '', actor: 'a');
      final b = await svc.create(
        title: 'Note B',
        content: 'refers to [[Old Name]]',
        actor: 'a',
      );

      await svc.update(
        id: a.id,
        title: 'New Name',
        content: '',
        ifMatch: 1,
        actor: 'alice',
      );

      final rewritten = await s.storage.read(b.id);
      expect(rewritten.content, 'refers to [[New Name]]');
      expect(rewritten.version, 2);
    });

    test('preserves the alias when rewriting an aliased link', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      addTearDown(s.locks.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        linkIndex: s.links,
        lockManager: s.locks,
      );

      final a = await svc.create(title: 'Old Name', content: '', actor: 'a');
      final b = await svc.create(
        title: 'Note B',
        content: 'see [[Old Name|the plan]]',
        actor: 'a',
      );

      await svc.update(
        id: a.id,
        title: 'New Name',
        content: '',
        ifMatch: 1,
        actor: 'alice',
      );

      final rewritten = await s.storage.read(b.id);
      expect(rewritten.content, 'see [[New Name|the plan]]');
    });

    test('does not touch an incidental plain-text mention', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      addTearDown(s.locks.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        linkIndex: s.links,
        lockManager: s.locks,
      );

      final a = await svc.create(title: 'Old Name', content: '', actor: 'a');
      final b = await svc.create(
        title: 'Note B',
        content: 'Old Name was a great project',
        actor: 'a',
      );

      await svc.update(
        id: a.id,
        title: 'New Name',
        content: '',
        ifMatch: 1,
        actor: 'alice',
      );

      final untouched = await s.storage.read(b.id);
      expect(untouched.content, 'Old Name was a great project');
      expect(untouched.version, 1);
    });

    test('a content-only update (no title change) does not propagate',
        () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      addTearDown(s.locks.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        linkIndex: s.links,
        lockManager: s.locks,
      );

      final a = await svc.create(title: 'Fixed Name', content: 'x', actor: 'a');
      final b = await svc.create(
        title: 'Note B',
        content: 'refers to [[Fixed Name]]',
        actor: 'a',
      );

      await svc.update(
        id: a.id,
        title: 'Fixed Name',
        content: 'x updated',
        ifMatch: 1,
        actor: 'a',
      );

      final untouched = await s.storage.read(b.id);
      expect(untouched.version, 1);
      expect(untouched.content, 'refers to [[Fixed Name]]');
    });

    test(
        'skips a referencing note locked by a different actor, with a '
        'warning naming the note id and holder', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      addTearDown(s.locks.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        linkIndex: s.links,
        lockManager: s.locks,
      );

      final a = await svc.create(title: 'Old Name', content: '', actor: 'a');
      final b = await svc.create(
        title: 'Note B',
        content: 'refers to [[Old Name]]',
        actor: 'a',
      );
      await s.locks.acquire(noteId: b.id, actor: 'bob');

      final logger = Logger.detached('note-write-propagation-test')
        ..level = Level.ALL;
      final records = <LogRecord>[];
      final sub = logger.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      final loggedSvc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        linkIndex: s.links,
        lockManager: s.locks,
        logger: logger,
      );

      await loggedSvc.update(
        id: a.id,
        title: 'New Name',
        content: '',
        ifMatch: 1,
        actor: 'alice',
      );

      final untouched = await s.storage.read(b.id);
      expect(untouched.content, 'refers to [[Old Name]]');
      expect(untouched.version, 1);
      expect(records, isNotEmpty);
      final message = records.map((r) => r.message).join('\n');
      expect(message, contains(b.id));
      expect(message, contains('bob'));
    });

    test('a referencing note locked by the renaming actor IS rewritten',
        () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      addTearDown(s.locks.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        linkIndex: s.links,
        lockManager: s.locks,
      );

      final a = await svc.create(title: 'Old Name', content: '', actor: 'a');
      final b = await svc.create(
        title: 'Note B',
        content: 'refers to [[Old Name]]',
        actor: 'a',
      );
      await s.locks.acquire(noteId: b.id, actor: 'alice');

      await svc.update(
        id: a.id,
        title: 'New Name',
        content: '',
        ifMatch: 1,
        actor: 'alice',
      );

      final rewritten = await s.storage.read(b.id);
      expect(rewritten.content, 'refers to [[New Name]]');
    });

    test(
        'each propagated rewrite broadcasts its own changed/updated event '
        'attributed to the renaming actor', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      addTearDown(s.locks.close);
      final bc = _CapturingBroadcaster();
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: bc,
        linkIndex: s.links,
        lockManager: s.locks,
      );

      final a = await svc.create(title: 'Old Name', content: '', actor: 'a');
      final b = await svc.create(
        title: 'Note B',
        content: 'refers to [[Old Name]]',
        actor: 'a',
      );
      final c = await svc.create(
        title: 'Note C',
        content: 'also [[Old Name|alias]]',
        actor: 'a',
      );

      await svc.update(
        id: a.id,
        title: 'New Name',
        content: '',
        ifMatch: 1,
        actor: 'alice',
      );

      final propagated = bc.changed.where(
        (e) =>
            (e.noteId == b.id || e.noteId == c.id) &&
            e.action == ChangeAction.updated,
      );
      expect(propagated, hasLength(2));
      for (final ev in propagated) {
        expect(ev.action, ChangeAction.updated);
        expect(ev.by, 'alice');
        expect(ev.version, 2);
      }
    });

    test('renaming to a title nobody links to does nothing extra', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      addTearDown(s.locks.close);
      final bc = _CapturingBroadcaster();
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: bc,
        linkIndex: s.links,
        lockManager: s.locks,
      );

      final a = await svc.create(title: 'Solo', content: '', actor: 'a');
      await svc.update(
        id: a.id,
        title: 'Solo Renamed',
        content: '',
        ifMatch: 1,
        actor: 'a',
      );

      expect(bc.changed, hasLength(2)); // created + the rename itself
    });
  });
}
