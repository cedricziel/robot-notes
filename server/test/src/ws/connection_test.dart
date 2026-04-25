import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/connection.dart';
import 'package:server/src/ws/presence.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

class _FakeSink implements WsSink {
  final List<String> sent = [];
  final List<({int code, String reason})> closes = [];
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  void send(String data) {
    if (_closed) return;
    sent.add(data);
  }

  @override
  void close(int code, String reason) {
    if (_closed) return;
    _closed = true;
    closes.add((code: code, reason: reason));
  }
}

Map<String, dynamic> _decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  late Broadcaster broadcaster;
  late PresenceTracker presence;
  const apiKey = 'rn_test';

  setUp(() {
    broadcaster = Broadcaster();
    presence = PresenceTracker();
  });

  tearDown(() async {
    await broadcaster.close();
  });

  WsConnection makeConn(
    String id, {
    required _FakeSink sink,
    Duration authTimeout = const Duration(seconds: 2),
  }) {
    return WsConnection(
      id: id,
      sink: sink,
      broadcaster: broadcaster,
      presence: presence,
      apiKey: apiKey,
      authTimeout: authTimeout,
    );
  }

  group('auth handshake', () {
    test('connection without auth within timeout closes 4001 auth_timeout', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final conn = makeConn('c1', sink: sink)..start();
        async.elapse(const Duration(seconds: 2));
        expect(conn.isClosed, isTrue);
        expect(sink.closes, hasLength(1));
        expect(sink.closes.single.code, 4001);
        expect(sink.closes.single.reason, 'auth_timeout');
      });
    });

    test('auth with wrong key closes 4001 auth_failed', () {
      final sink = _FakeSink();
      makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'auth', 'key': 'nope'}));
      expect(sink.closes, hasLength(1));
      expect(sink.closes.single.code, 4001);
      expect(sink.closes.single.reason, 'auth_failed');
    });

    test('successful auth sends auth_ok and binds actor', () {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(
          jsonEncode({
            'type': 'auth',
            'key': apiKey,
            'actor': 'alice',
          }),
        );
      expect(conn.isAuthed, isTrue);
      expect(conn.actor!.name, 'alice');
      expect(sink.closes, isEmpty);
      expect(sink.sent, hasLength(1));
      expect(_decode(sink.sent.single)['type'], 'auth_ok');
    });

    test('auth without "actor" defaults to "unknown"', () {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}));
      expect(conn.actor!.name, 'unknown');
    });

    test('successful auth cancels the auth timer', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final conn = makeConn('c1', sink: sink)
          ..start()
          ..handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}));
        async.elapse(const Duration(seconds: 5));
        expect(conn.isClosed, isFalse);
        expect(sink.closes, isEmpty);
      });
    });
  });

  group('pre-auth message handling', () {
    test('subscribe before auth is silently ignored', () async {
      final sink = _FakeSink();
      makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'n1'}));
      broadcaster.emitLock(const LockEvent(noteId: 'n1', holder: 'alice'));
      await Future<void>.delayed(Duration.zero);
      expect(sink.sent, isEmpty);
      expect(broadcaster.isRegistered('c1'), isFalse);
    });

    test('ping before auth is silently ignored', () {
      final sink = _FakeSink();
      makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'ping', 'id': 'x'}));
      expect(sink.sent, isEmpty);
    });

    test('unknown message before auth is silently ignored', () {
      final sink = _FakeSink();
      makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'something_weird'}));
      expect(sink.sent, isEmpty);
    });
  });

  group('subscribe / unsubscribe', () {
    Future<WsConnection> authed(
      String id,
      _FakeSink sink, {
      String actor = 'alice',
    }) async {
      final conn = makeConn(id, sink: sink)
        ..start()
        ..handleMessage(
          jsonEncode({
            'type': 'auth',
            'key': apiKey,
            'actor': actor,
          }),
        );
      // Drain any synchronous follow-up (auth_ok is sync, but subscribe to
      // broadcaster registers a listener — both complete by next tick).
      await Future<void>.delayed(Duration.zero);
      return conn;
    }

    test('per-note subscribe forwards events for that note only', () async {
      final sink = _FakeSink();
      final conn = await authed('c1', sink);
      sink.sent.clear();

      conn.handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'n1'}));
      await Future<void>.delayed(Duration.zero);
      // Subscribing emits a presence event for the new viewer. Ignore it
      // for the routing assertions below.
      sink.sent.clear();

      broadcaster
        ..emitLock(const LockEvent(noteId: 'n1', holder: 'alice'))
        ..emitLock(const LockEvent(noteId: 'n2', holder: 'bob'));
      await Future<void>.delayed(Duration.zero);

      final types = sink.sent.map((s) => _decode(s)['type']).toList();
      final ids = sink.sent.map((s) => _decode(s)['note_id']).toList();
      expect(types, ['lock']);
      expect(ids, ['n1']);
    });

    test('wildcard subscribe forwards events for any note', () async {
      final sink = _FakeSink();
      final conn = await authed('c1', sink);
      sink.sent.clear();

      conn.handleMessage(jsonEncode({'type': 'subscribe', 'note_id': '*'}));
      await Future<void>.delayed(Duration.zero);

      broadcaster
        ..emitLock(const LockEvent(noteId: 'n1', holder: 'alice'))
        ..emitLock(const LockEvent(noteId: 'n2', holder: 'bob'));
      await Future<void>.delayed(Duration.zero);

      expect(sink.sent.length, 2);
    });

    test('unsubscribe stops further delivery for that note', () async {
      final sink = _FakeSink();
      final conn = await authed('c1', sink);
      sink.sent.clear();

      conn
        ..handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'n1'}))
        ..handleMessage(jsonEncode({'type': 'unsubscribe', 'note_id': 'n1'}));
      await Future<void>.delayed(Duration.zero);
      sink.sent.clear();

      broadcaster.emitLock(const LockEvent(noteId: 'n1'));
      await Future<void>.delayed(Duration.zero);

      expect(sink.sent, isEmpty);
    });
  });

  group('presence', () {
    Future<WsConnection> authedAndSubscribed(
      String id,
      _FakeSink sink,
      String actor,
      String noteId,
    ) async {
      final conn = makeConn(id, sink: sink)
        ..start()
        ..handleMessage(
          jsonEncode({
            'type': 'auth',
            'key': apiKey,
            'actor': actor,
          }),
        );
      await Future<void>.delayed(Duration.zero);
      conn.handleMessage(jsonEncode({'type': 'subscribe', 'note_id': noteId}));
      await Future<void>.delayed(Duration.zero);
      return conn;
    }

    test('subscribing fans out a presence event to existing viewers', () async {
      final sinkA = _FakeSink();
      await authedAndSubscribed('cA', sinkA, 'alice', 'n1');
      sinkA.sent.clear();

      final sinkB = _FakeSink();
      await authedAndSubscribed('cB', sinkB, 'bob', 'n1');

      // Both sinks should now have a presence frame describing alice+bob.
      final eventsA = sinkA.sent.map(_decode).toList();
      expect(eventsA.last['type'], 'presence');
      expect(eventsA.last['viewers'], ['alice', 'bob']);
    });

    test('disconnecting removes the actor from presence', () async {
      final sinkA = _FakeSink();
      final connA = await authedAndSubscribed('cA', sinkA, 'alice', 'n1');
      final sinkB = _FakeSink();
      await authedAndSubscribed('cB', sinkB, 'bob', 'n1');
      sinkA.sent.clear();
      sinkB.sent.clear();

      await connA.handleDone();
      await Future<void>.delayed(Duration.zero);

      // bob's sink should see a presence event reflecting alice's departure.
      final last = _decode(sinkB.sent.last);
      expect(last['type'], 'presence');
      expect(last['viewers'], ['bob']);
    });

    test('same actor on two connections appears once in presence', () async {
      final sinkA = _FakeSink();
      await authedAndSubscribed('cA', sinkA, 'alice', 'n1');
      final sinkB = _FakeSink();
      await authedAndSubscribed('cB', sinkB, 'alice', 'n1');

      // Walk every presence event observed by either sink and confirm it
      // never lists alice twice.
      final all = [...sinkA.sent, ...sinkB.sent]
          .map(_decode)
          .where((m) => m['type'] == 'presence')
          .toList();
      for (final ev in all) {
        final viewers = (ev['viewers'] as List).cast<String>();
        final aliceCount = viewers.where((v) => v == 'alice').length;
        expect(aliceCount, lessThanOrEqualTo(1));
      }
    });
  });

  group('lock + changed events', () {
    test('lock event propagates to subscribed connection', () async {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}));
      await Future<void>.delayed(Duration.zero);
      conn.handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'n1'}));
      await Future<void>.delayed(Duration.zero);
      sink.sent.clear();

      broadcaster.emitLock(const LockEvent(noteId: 'n1', holder: 'alice'));
      await Future<void>.delayed(Duration.zero);

      expect(_decode(sink.sent.single)['type'], 'lock');
    });

    test('changed event does NOT include content', () async {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}));
      await Future<void>.delayed(Duration.zero);
      conn.handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'n1'}));
      await Future<void>.delayed(Duration.zero);
      sink.sent.clear();

      broadcaster.emitChanged(
        const ChangedEvent(
          noteId: 'n1',
          version: 2,
          by: 'alice',
          action: ChangeAction.updated,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final body = _decode(sink.sent.single);
      expect(body['type'], 'changed');
      expect(body.containsKey('content'), isFalse);
    });
  });

  group('ping / pong', () {
    test('ping is echoed with the same id', () {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}))
        ..handleMessage(jsonEncode({'type': 'ping', 'id': 'abc-123'}));
      expect(conn.isAuthed, isTrue);

      final pongs =
          sink.sent.map(_decode).where((m) => m['type'] == 'pong').toList();
      expect(pongs, hasLength(1));
      expect(pongs.single['id'], 'abc-123');
    });
  });

  group('error handling', () {
    test('binary frame closes 1003 unsupported_data', () {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage([0x01, 0x02, 0x03]);
      expect(conn.isClosed, isTrue);
      expect(sink.closes.single.code, 1003);
    });

    test('unknown message type after auth surfaces as error envelope',
        () async {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}));
      await Future<void>.delayed(Duration.zero);
      sink.sent.clear();

      conn.handleMessage(jsonEncode({'type': 'foo'}));
      expect(conn.isClosed, isFalse);
      final body = _decode(sink.sent.single);
      expect(body['type'], 'error');
      expect(body['error'], 'unknown_type');
    });

    test('malformed JSON after auth surfaces as error envelope', () async {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}));
      await Future<void>.delayed(Duration.zero);
      sink.sent.clear();

      conn.handleMessage('this-is-not-json');
      expect(conn.isClosed, isFalse);
      expect(_decode(sink.sent.single)['type'], 'error');
    });
  });

  group('disconnect cleanup', () {
    test('handleDone clears presence and broadcaster registration', () async {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(
          jsonEncode({
            'type': 'auth',
            'key': apiKey,
            'actor': 'alice',
          }),
        );
      await Future<void>.delayed(Duration.zero);
      conn.handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'n1'}));
      await Future<void>.delayed(Duration.zero);

      expect(broadcaster.isRegistered('c1'), isTrue);
      await conn.handleDone();
      await Future<void>.delayed(Duration.zero);
      expect(broadcaster.isRegistered('c1'), isFalse);
      expect(presence.viewersOf('n1'), isEmpty);
    });
  });
}
