import 'dart:async';
import 'dart:io';

import 'package:dart_otel_sdk/dart_otel_sdk.dart' hide LogRecord, Logger;
import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/embeddings/embedding_provider.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'embeddings/fake_embedding_provider.dart';
import 'search_test_helpers.dart';

class _RecordingSpanProcessor implements SpanProcessor {
  final List<SpanData> ended = [];

  @override
  void onEnd(SpanData span) => ended.add(span);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

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
  Directory tmp, {
  EmbeddingProvider? embeddingProvider,
}) async {
  final storage = Storage(
    contentDir: Directory('${tmp.path}/content'),
    clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
  );
  final meta = MetaIndex();
  final search = await SearchIndex.open(
    dbFile: File('${tmp.path}/search.db'),
    storage: storage,
    embeddingProvider: embeddingProvider,
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
      final hits = await s.search.search('dust');
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
      final fresh = await s.search.search('telescopes');
      expect(fresh, hasLength(1));
      final old = await s.search.search('"old body"');
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

  group('NoteWriteService.update path changes', () {
    test('a path change broadcasts action: moved, not updated', () async {
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
        title: 'Inbox',
        content: 'todo',
        actor: 'a',
      );

      final moved = await svc.update(
        id: note.id,
        title: 'Inbox',
        content: 'todo',
        ifMatch: 1,
        actor: 'b',
        path: 'Projects/Alpha',
      );

      expect(moved.path, 'Projects/Alpha');
      expect(bc.changed.last.action, ChangeAction.moved);
      expect(bc.changed.last.version, 2);
      expect(bc.changed.last.by, 'b');
      expect(s.meta.page().items.single.path, 'Projects/Alpha');
    });

    test('a title-only change (no path) still broadcasts updated', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final bc = _CapturingBroadcaster();
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: bc,
      );

      final note = await svc.create(title: 'Draft', content: 'c', actor: 'a');
      await svc.update(
        id: note.id,
        title: 'Final',
        content: 'c',
        ifMatch: 1,
        actor: 'a',
      );

      expect(bc.changed.last.action, ChangeAction.updated);
    });

    test('creating under a path stores it on the note', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
      );

      final note = await svc.create(
        title: 'Nested',
        content: 'c',
        actor: 'a',
        path: 'Projects/Alpha',
      );

      expect(note.path, 'Projects/Alpha');
      expect(s.meta.page().items.single.path, 'Projects/Alpha');
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
      expect(await s.search.search('erased'), isEmpty);

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
      expect((await s.search.search('crater')).single.id, note.id);
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
      expect((await s.search.search('death')).single.id, note.id);
      expect(s.meta.length, 1);
      expect(captured, contains(Level.WARNING));
    });
  });

  group('NoteWriteService tracing and logging', () {
    // Bundles a fresh traced service with the processor recording its
    // spans, and — since update/delete need a note to already exist — an
    // optional seed note created through an untraced sibling service
    // first, so its own `note.write.create` span doesn't pollute the
    // recording.
    Future<
        ({
          _RecordingSpanProcessor processor,
          NoteWriteService traced,
          StoredNote? seed,
        })> tracedFixture(
      ({Storage storage, MetaIndex meta, SearchIndex search}) s, {
      bool withSeedNote = false,
    }) async {
      StoredNote? seed;
      if (withSeedNote) {
        final bare = NoteWriteService(
          storage: s.storage,
          metaIndex: s.meta,
          searchIndex: s.search,
          broadcaster: _CapturingBroadcaster(),
        );
        seed = await bare.create(title: 'V1', content: 'c', actor: 'a');
      }
      final processor = _RecordingSpanProcessor();
      final tracer = SdkTracer(
        name: 'test',
        version: null,
        processor: processor,
      );
      final traced = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        tracer: tracer,
      );
      return (processor: processor, traced: traced, seed: seed);
    }

    test(
      'create starts a note.write.create span naming the new note',
      () async {
        final s = await _stack(tmp);
        addTearDown(s.search.close);
        final f = await tracedFixture(s);

        final note = await f.traced.create(
          title: 'Traced',
          content: 'body',
          actor: 'a',
        );

        final span = f.processor.ended.single;
        expect(span.name, 'note.write.create');
        expect(span.attributes['note.id'], note.id);
        expect(span.statusCode, StatusCode.unset);
      },
    );

    test('create logs an info record naming the new note', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final logger = Logger.detached('write-svc-test')..level = Level.ALL;
      final records = <LogRecord>[];
      final sub = logger.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        logger: logger,
      );

      final note = await svc.create(
        title: 'Logged',
        content: 'body',
        actor: 'orbit-bot',
      );

      final info =
          records.where((r) => r.level == Level.INFO).map((r) => r.message);
      expect(info, contains(contains(note.id)));
      expect(info, contains(contains('orbit-bot')));
    });

    test('update starts a note.write.update span naming the note', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final f = await tracedFixture(s, withSeedNote: true);

      await f.traced.update(
        id: f.seed!.id,
        title: 'V2',
        content: 'c2',
        ifMatch: f.seed!.version,
        actor: 'a',
      );

      final span = f.processor.ended.single;
      expect(span.name, 'note.write.update');
      expect(span.attributes['note.id'], f.seed!.id);
    });

    test('a failed update records the exception on the span', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final f = await tracedFixture(s, withSeedNote: true);

      await expectLater(
        f.traced.update(
          id: f.seed!.id,
          title: 'V2',
          content: 'c2',
          ifMatch: f.seed!.version + 1,
          actor: 'a',
        ),
        throwsA(isA<VersionConflictException>()),
      );

      final span = f.processor.ended.single;
      expect(span.statusCode, StatusCode.error);
      expect(span.events.single.name, 'exception');
    });

    test('delete starts a note.write.delete span naming the note', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final f = await tracedFixture(s, withSeedNote: true);

      await f.traced.delete(id: f.seed!.id, actor: 'a');

      final span = f.processor.ended.single;
      expect(span.name, 'note.write.delete');
      expect(span.attributes['note.id'], f.seed!.id);
      expect(span.statusCode, StatusCode.unset);
    });
  });

  group('NoteWriteService embedding integration', () {
    test(
        'create computes and stores an embedding when a provider is '
        'configured', () async {
      final provider = FakeEmbeddingProvider();
      final s = await _stack(tmp, embeddingProvider: provider);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        embeddingProvider: provider,
      );

      final note = await svc.create(
        title: 'Auth notes',
        content: 'switching to OAuth for third-party login',
        actor: 'a',
      );

      expect(provider.callCount, 1);
      expect(
        provider.inputs.single,
        'Auth notes\n\nswitching to OAuth for third-party login',
      );
      expect(vectorRowExists('${tmp.path}/search.db', note.id), isTrue);
    });

    test('create embeds a note with an empty body from its title', () async {
      final provider = FakeEmbeddingProvider();
      final s = await _stack(tmp, embeddingProvider: provider);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        embeddingProvider: provider,
      );

      final note = await svc.create(
        title: '2026-09-18 Untitled',
        content: '',
        actor: 'a',
      );

      expect(provider.inputs.single, '2026-09-18 Untitled');
      expect(vectorRowExists('${tmp.path}/search.db', note.id), isTrue);
    });

    test('update recomputes the embedding', () async {
      final provider = FakeEmbeddingProvider();
      final s = await _stack(tmp, embeddingProvider: provider);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        embeddingProvider: provider,
      );
      final note = await svc.create(title: 'A', content: 'v1', actor: 'a');
      provider.callCount = 0;

      await svc.update(
        id: note.id,
        title: 'A',
        content: 'v2',
        ifMatch: note.version,
        actor: 'a',
      );

      expect(provider.callCount, 1);
      expect(vectorRowExists('${tmp.path}/search.db', note.id), isTrue);
    });

    test('write still succeeds when the embedding provider fails', () async {
      final provider = FakeEmbeddingProvider()..shouldThrow = true;
      final s = await _stack(tmp, embeddingProvider: provider);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        embeddingProvider: provider,
      );

      final note = await svc.create(
        title: 'A',
        content: 'still findable by keyword',
        actor: 'a',
      );

      expect(await s.search.search('findable'), hasLength(1));
      expect(vectorRowExists('${tmp.path}/search.db', note.id), isFalse);
    });

    test(
        'update drops a stale vector when the embedding provider fails, '
        'and backfill later regenerates it', () async {
      final provider = FakeEmbeddingProvider();
      final s = await _stack(tmp, embeddingProvider: provider);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
        embeddingProvider: provider,
      );
      final note = await svc.create(title: 'A', content: 'v1', actor: 'a');
      expect(vectorRowExists('${tmp.path}/search.db', note.id), isTrue);

      provider.shouldThrow = true;
      await svc.update(
        id: note.id,
        title: 'A',
        content: 'v2',
        ifMatch: note.version,
        actor: 'a',
      );

      expect(
        vectorRowExists('${tmp.path}/search.db', note.id),
        isFalse,
        reason: 'a failed re-embed must drop the old vector rather than leave '
            "the pre-update content's embedding behind",
      );

      provider.shouldThrow = false;
      await s.search.backfillEmbeddings();

      expect(vectorRowExists('${tmp.path}/search.db', note.id), isTrue);
    });

    test('does not call embed at all when no provider is configured', () async {
      final s = await _stack(tmp);
      addTearDown(s.search.close);
      final svc = NoteWriteService(
        storage: s.storage,
        metaIndex: s.meta,
        searchIndex: s.search,
        broadcaster: _CapturingBroadcaster(),
      );

      await svc.create(title: 'A', content: 'no provider here', actor: 'a');

      expect(await s.search.search('provider'), hasLength(1));
    });
  });
}
