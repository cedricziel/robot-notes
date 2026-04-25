import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  late Broadcaster broadcaster;

  setUp(() {
    broadcaster = Broadcaster();
  });

  tearDown(() async {
    await broadcaster.close();
  });

  group('register', () {
    test('returns a stream and tracks the connection', () {
      final stream = broadcaster.register('c1');
      expect(stream, isA<Stream<WsMessage>>());
      expect(broadcaster.connectionCount, 1);
      expect(broadcaster.isRegistered('c1'), isTrue);
    });

    test('throws StateError on duplicate registration', () {
      broadcaster.register('c1');
      expect(() => broadcaster.register('c1'), throwsStateError);
    });
  });

  group('per-note subscription', () {
    test('subscriber receives lock event for matching note', () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribe('c1', 'note-1')
        ..emitLock(const LockEvent(noteId: 'note-1', holder: 'alice'));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      final ev = received.single as LockEvent;
      expect(ev.noteId, 'note-1');
      expect(ev.holder, 'alice');
    });

    test('subscriber does NOT receive events for other notes', () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribe('c1', 'note-1')
        ..emitLock(const LockEvent(noteId: 'note-2', holder: 'bob'));
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
    });

    test('subscriber receives changed events for the subscribed note',
        () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribe('c1', 'note-1')
        ..emitChanged(
          const ChangedEvent(
            noteId: 'note-1',
            version: 2,
            by: 'alice',
            action: ChangeAction.updated,
          ),
        );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single, isA<ChangedEvent>());
    });

    test('subscribing to multiple notes routes events for each', () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribe('c1', 'note-1')
        ..subscribe('c1', 'note-2')
        ..emitLock(const LockEvent(noteId: 'note-1'))
        ..emitLock(const LockEvent(noteId: 'note-2'))
        ..emitLock(const LockEvent(noteId: 'note-3'));
      await Future<void>.delayed(Duration.zero);

      final ids = received.map((e) => (e as LockEvent).noteId).toList();
      expect(ids, ['note-1', 'note-2']);
    });

    test('idempotent subscribe does not double-deliver', () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribe('c1', 'note-1')
        ..subscribe('c1', 'note-1')
        ..emitLock(const LockEvent(noteId: 'note-1'));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
    });
  });

  group('wildcard subscription', () {
    test('wildcard subscriber receives events for any note', () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribeWildcard('c1')
        ..emitLock(const LockEvent(noteId: 'note-1'))
        ..emitLock(const LockEvent(noteId: 'note-2'))
        ..emitChanged(
          const ChangedEvent(
            noteId: 'note-3',
            version: 1,
            by: 'alice',
            action: ChangeAction.created,
          ),
        );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(3));
    });

    test('wildcard remains in effect even after a per-note unsubscribe',
        () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribeWildcard('c1')
        ..subscribe('c1', 'note-1')
        ..unsubscribe('c1', 'note-1')
        ..emitLock(const LockEvent(noteId: 'note-1'));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
    });
  });

  group('unsubscribe', () {
    test('stops delivery for the unsubscribed note', () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribe('c1', 'note-1')
        ..unsubscribe('c1', 'note-1')
        ..emitLock(const LockEvent(noteId: 'note-1'));
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
    });

    test('only affects the targeted note', () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster
        ..subscribe('c1', 'note-1')
        ..subscribe('c1', 'note-2')
        ..unsubscribe('c1', 'note-1')
        ..emitLock(const LockEvent(noteId: 'note-2'));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect((received.single as LockEvent).noteId, 'note-2');
    });

    test('on unregistered connection is a no-op', () {
      expect(
        () => broadcaster.unsubscribe('ghost', 'note-1'),
        returnsNormally,
      );
    });
  });

  group('disconnect', () {
    test('closes the per-connection stream', () async {
      final stream = broadcaster.register('c1');
      var done = false;
      stream.listen(
        (_) {},
        onDone: () => done = true,
      );

      await broadcaster.disconnect('c1');
      await Future<void>.delayed(Duration.zero);

      expect(done, isTrue);
      expect(broadcaster.isRegistered('c1'), isFalse);
    });

    test('stops further delivery to that connection', () async {
      final received = <WsMessage>[];
      broadcaster.register('c1').listen(received.add);
      broadcaster.subscribe('c1', 'note-1');
      await broadcaster.disconnect('c1');
      broadcaster.emitLock(const LockEvent(noteId: 'note-1'));
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
    });

    test('on unknown connection is a no-op', () {
      expect(broadcaster.disconnect('ghost'), completes);
    });
  });

  group('multiple subscribers', () {
    test('only matching subscribers receive an event', () async {
      final receivedA = <WsMessage>[];
      final receivedB = <WsMessage>[];
      broadcaster.register('a').listen(receivedA.add);
      broadcaster.register('b').listen(receivedB.add);
      broadcaster
        ..subscribe('a', 'note-1')
        ..subscribe('b', 'note-2')
        ..emitLock(const LockEvent(noteId: 'note-1'));
      await Future<void>.delayed(Duration.zero);

      expect(receivedA, hasLength(1));
      expect(receivedB, isEmpty);
    });

    test('emits to every wildcard subscriber regardless of note', () async {
      final received1 = <WsMessage>[];
      final received2 = <WsMessage>[];
      broadcaster.register('a').listen(received1.add);
      broadcaster.register('b').listen(received2.add);
      broadcaster
        ..subscribeWildcard('a')
        ..subscribeWildcard('b')
        ..emitLock(const LockEvent(noteId: 'whatever'));
      await Future<void>.delayed(Duration.zero);

      expect(received1, hasLength(1));
      expect(received2, hasLength(1));
    });
  });

  group('close', () {
    test('disconnects every registered connection', () async {
      final s1 = broadcaster.register('a');
      final s2 = broadcaster.register('b');
      var done1 = false;
      var done2 = false;
      s1.listen((_) {}, onDone: () => done1 = true);
      s2.listen((_) {}, onDone: () => done2 = true);

      await broadcaster.close();
      await Future<void>.delayed(Duration.zero);

      expect(done1, isTrue);
      expect(done2, isTrue);
      expect(broadcaster.connectionCount, 0);
    });
  });
}
