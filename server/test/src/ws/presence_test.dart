import 'package:server/src/ws/presence.dart';
import 'package:test/test.dart';

void main() {
  late PresenceTracker tracker;

  setUp(() {
    tracker = PresenceTracker();
  });

  group('viewersOf', () {
    test('returns empty list for an unknown note', () {
      expect(tracker.viewersOf('note-x'), isEmpty);
    });

    test('returns sorted unique actor names', () {
      tracker
        ..add('c1', 'charlie', 'note-1')
        ..add('c2', 'alice', 'note-1')
        ..add('c3', 'bob', 'note-1');
      expect(tracker.viewersOf('note-1'), ['alice', 'bob', 'charlie']);
    });
  });

  group('add', () {
    test('first add returns a PresenceEvent listing the new viewer', () {
      final ev = tracker.add('c1', 'alice', 'note-1');
      expect(ev, isNotNull);
      expect(ev!.noteId, 'note-1');
      expect(ev.viewers, ['alice']);
    });

    test('second add by same actor on same note (different conn) is no-op', () {
      tracker.add('c1', 'alice', 'note-1');
      final ev = tracker.add('c2', 'alice', 'note-1');
      expect(ev, isNull);
      expect(tracker.viewersOf('note-1'), ['alice']);
    });

    test('add of new actor returns event with merged sorted viewers', () {
      tracker.add('c1', 'alice', 'note-1');
      final ev = tracker.add('c2', 'bob', 'note-1');
      expect(ev, isNotNull);
      expect(ev!.viewers, ['alice', 'bob']);
    });

    test('repeated add by same conn for same actor on same note is no-op', () {
      tracker.add('c1', 'alice', 'note-1');
      final ev = tracker.add('c1', 'alice', 'note-1');
      expect(ev, isNull);
    });

    test('actors are tracked per note', () {
      tracker
        ..add('c1', 'alice', 'note-1')
        ..add('c2', 'bob', 'note-2');
      expect(tracker.viewersOf('note-1'), ['alice']);
      expect(tracker.viewersOf('note-2'), ['bob']);
    });
  });

  group('remove', () {
    test('removing the only viewer emits an event with empty viewer list', () {
      tracker.add('c1', 'alice', 'note-1');
      final ev = tracker.remove('c1', 'note-1');
      expect(ev, isNotNull);
      expect(ev!.viewers, isEmpty);
      expect(tracker.viewersOf('note-1'), isEmpty);
    });

    test('removing one of two connections by same actor is a no-op', () {
      tracker
        ..add('c1', 'alice', 'note-1')
        ..add('c2', 'alice', 'note-1');
      final ev = tracker.remove('c1', 'note-1');
      expect(ev, isNull);
      expect(tracker.viewersOf('note-1'), ['alice']);
    });

    test('removing the last connection of an actor does emit an event', () {
      tracker
        ..add('c1', 'alice', 'note-1')
        ..add('c2', 'alice', 'note-1')
        ..remove('c1', 'note-1');
      final ev = tracker.remove('c2', 'note-1');
      expect(ev, isNotNull);
      expect(ev!.viewers, isEmpty);
    });

    test('remove of an unknown connection is null', () {
      final ev = tracker.remove('ghost', 'note-1');
      expect(ev, isNull);
    });

    test('remove from an unknown note is null', () {
      tracker.add('c1', 'alice', 'note-1');
      final ev = tracker.remove('c1', 'note-x');
      expect(ev, isNull);
    });
  });

  group('disconnect', () {
    test('emits a presence event per affected note', () {
      tracker
        ..add('c1', 'alice', 'note-1')
        ..add('c1', 'alice', 'note-2')
        ..add('c2', 'bob', 'note-1');
      final events = tracker.disconnect('c1');
      expect(events.keys.toSet(), {'note-1', 'note-2'});
      expect(events['note-1']!.viewers, ['bob']);
      expect(events['note-2']!.viewers, isEmpty);
    });

    test('does not emit for notes where the actor still has another conn', () {
      tracker
        ..add('c1', 'alice', 'note-1')
        ..add('c2', 'alice', 'note-1');
      final events = tracker.disconnect('c1');
      expect(events, isEmpty);
      expect(tracker.viewersOf('note-1'), ['alice']);
    });

    test('on unknown connection returns empty', () {
      expect(tracker.disconnect('ghost'), isEmpty);
    });

    test('clears the connection from internal indices', () {
      tracker
        ..add('c1', 'alice', 'note-1')
        ..add('c1', 'alice', 'note-2')
        ..disconnect('c1');
      expect(tracker.watchedNoteCount, 0);
    });
  });
}
