import 'package:server/src/clock.dart';
import 'package:server/src/lock_manager.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

DateTime _t(int second) => DateTime.utc(2026, 4, 25, 10, 0, second);

void main() {
  group('LockManager.acquire', () {
    test('succeeds when no lock exists and emits a transition', () async {
      final clock = FixedClock([_t(0)]);
      final mgr = LockManager(clock: clock);
      final events = <LockEvent>[];
      final sub = mgr.transitions.listen(events.add);

      final lock = await mgr.acquire(noteId: 'n1', actor: 'alice');

      expect(lock.holder, 'alice');
      expect(lock.expiresAt, _t(60));
      // Allow the broadcast controller to flush the buffered event.
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.noteId, 'n1');
      expect(events.single.holder, 'alice');
      expect(events.single.expiresAt, _t(60));

      await sub.cancel();
      await mgr.close();
    });

    test('throws LockedException when held by a different actor', () async {
      final clock = FixedClock([_t(0)]);
      final mgr = LockManager(clock: clock);
      await mgr.acquire(noteId: 'n1', actor: 'alice');

      await expectLater(
        () => mgr.acquire(noteId: 'n1', actor: 'bob'),
        throwsA(
          isA<LockedException>()
              .having((e) => e.actor, 'actor', 'bob')
              .having((e) => e.current.holder, 'current.holder', 'alice'),
        ),
      );

      await mgr.close();
    });

    test('same-actor re-acquire extends TTL and is idempotent', () async {
      final clock = FixedClock([_t(0), _t(30)]);
      final mgr = LockManager(clock: clock);

      final first = await mgr.acquire(noteId: 'n1', actor: 'alice');
      expect(first.expiresAt, _t(60));

      final second = await mgr.acquire(noteId: 'n1', actor: 'alice');
      expect(second.holder, 'alice');
      expect(second.expiresAt, _t(90));
      expect(mgr.lockOf('n1')?.expiresAt, _t(90));

      await mgr.close();
    });

    test('acquire on an expired lock succeeds for any actor', () async {
      final clock = FixedClock([_t(0), _t(120)]);
      final mgr = LockManager(clock: clock);
      await mgr.acquire(noteId: 'n1', actor: 'alice');

      // Time advances past expiry; bob should succeed.
      final taken = await mgr.acquire(noteId: 'n1', actor: 'bob');
      expect(taken.holder, 'bob');
      expect(taken.expiresAt, _t(180));

      await mgr.close();
    });
  });

  group('LockManager.heartbeat', () {
    test('by holder extends expiresAt', () async {
      final clock = FixedClock([_t(0), _t(30)]);
      final mgr = LockManager(clock: clock);
      await mgr.acquire(noteId: 'n1', actor: 'alice');

      final beat = await mgr.heartbeat(noteId: 'n1', actor: 'alice');
      expect(beat.holder, 'alice');
      expect(beat.expiresAt, _t(90));

      await mgr.close();
    });

    test('by non-holder throws LockedException', () async {
      final clock = FixedClock([_t(0)]);
      final mgr = LockManager(clock: clock);
      await mgr.acquire(noteId: 'n1', actor: 'alice');

      await expectLater(
        () => mgr.heartbeat(noteId: 'n1', actor: 'bob'),
        throwsA(isA<LockedException>()),
      );

      await mgr.close();
    });

    test('on an expired lock throws LockNotFoundException', () async {
      final clock = FixedClock([_t(0), _t(120)]);
      final mgr = LockManager(clock: clock);
      await mgr.acquire(noteId: 'n1', actor: 'alice');

      await expectLater(
        () => mgr.heartbeat(noteId: 'n1', actor: 'alice'),
        throwsA(isA<LockNotFoundException>()),
      );

      await mgr.close();
    });
  });

  group('LockManager.release', () {
    test('by holder clears state and emits release event', () async {
      final clock = FixedClock([_t(0)]);
      final mgr = LockManager(clock: clock);
      final events = <LockEvent>[];
      final sub = mgr.transitions.listen(events.add);

      await mgr.acquire(noteId: 'n1', actor: 'alice');
      await mgr.release(noteId: 'n1', actor: 'alice');

      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      expect(events.last.holder, isNull);
      expect(events.last.expiresAt, isNull);
      expect(mgr.lockOf('n1'), isNull);

      await sub.cancel();
      await mgr.close();
    });

    test('by non-holder throws LockedException', () async {
      final clock = FixedClock([_t(0)]);
      final mgr = LockManager(clock: clock);
      await mgr.acquire(noteId: 'n1', actor: 'alice');

      await expectLater(
        () => mgr.release(noteId: 'n1', actor: 'bob'),
        throwsA(isA<LockedException>()),
      );

      await mgr.close();
    });

    test('release of missing lock is a no-op', () async {
      final mgr = LockManager(clock: FixedClock.fixed(_t(0)));
      await expectLater(
        mgr.release(noteId: 'never', actor: 'anyone'),
        completes,
      );
      await mgr.close();
    });

    test('release of an expired lock is a no-op', () async {
      final clock = FixedClock([_t(0), _t(120)]);
      final mgr = LockManager(clock: clock);
      await mgr.acquire(noteId: 'n1', actor: 'alice');

      // The lock has now expired; even bob (a non-holder) can release
      // without an exception because expiry collapses the state first.
      await expectLater(
        mgr.release(noteId: 'n1', actor: 'bob'),
        completes,
      );

      await mgr.close();
    });
  });

  group('LockManager.lockOf', () {
    test('returns null and emits release when current lock is expired',
        () async {
      final clock = FixedClock([_t(0), _t(120)]);
      final mgr = LockManager(clock: clock);
      final events = <LockEvent>[];
      final sub = mgr.transitions.listen(events.add);

      await mgr.acquire(noteId: 'n1', actor: 'alice');
      events.clear();

      // Time has advanced past expiry. lockOf should return null and emit
      // a release transition exactly once.
      expect(mgr.lockOf('n1'), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.holder, isNull);

      // A second call after the eviction is silent.
      events.clear();
      expect(mgr.lockOf('n1'), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      await sub.cancel();
      await mgr.close();
    });

    test('returns null for an unseen note id without emitting anything',
        () async {
      final mgr = LockManager(clock: FixedClock.fixed(_t(0)));
      final events = <LockEvent>[];
      final sub = mgr.transitions.listen(events.add);

      expect(mgr.lockOf('nope'), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      await sub.cancel();
      await mgr.close();
    });
  });

  group('LockManager.transitions', () {
    test('emits acquire, heartbeat, and release events in order', () async {
      // Moments are consumed in this order:
      //   acquire  → 1 reading (new Lock)            → _t(0)
      //   heartbeat → 2 readings (_evict + new Lock) → _t(30), _t(30)
      //   release  → 1 reading (_evict)              → _t(45)
      final clock = FixedClock([_t(0), _t(30), _t(30), _t(45)]);
      final mgr = LockManager(clock: clock);
      final events = <LockEvent>[];
      final sub = mgr.transitions.listen(events.add);

      await mgr.acquire(noteId: 'n1', actor: 'alice');
      await mgr.heartbeat(noteId: 'n1', actor: 'alice');
      await mgr.release(noteId: 'n1', actor: 'alice');

      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(3));
      expect(events[0].holder, 'alice');
      expect(events[0].expiresAt, _t(60));
      expect(events[1].holder, 'alice');
      expect(events[1].expiresAt, _t(90));
      expect(events[2].holder, isNull);
      expect(events[2].expiresAt, isNull);

      await sub.cancel();
      await mgr.close();
    });

    test('emits an expiry transition when a stale lock is observed', () async {
      final clock = FixedClock([_t(0), _t(120)]);
      final mgr = LockManager(clock: clock);
      final events = <LockEvent>[];
      final sub = mgr.transitions.listen(events.add);

      await mgr.acquire(noteId: 'n1', actor: 'alice');
      // First call past expiry collapses the slot and emits the release.
      mgr.lockOf('n1');

      await Future<void>.delayed(Duration.zero);
      expect(events.last.holder, isNull);

      await sub.cancel();
      await mgr.close();
    });
  });
}
