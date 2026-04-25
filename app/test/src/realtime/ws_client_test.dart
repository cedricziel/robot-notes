import 'dart:async';
import 'dart:convert';

import 'package:app/src/config/app_config.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

/// Programmable [WsConnection] for tests. Buffers outbound frames so the
/// test can assert what the client sent (and in what order), and lets the
/// test push inbound frames or close the connection on demand.
class FakeConnection implements WsConnection {
  FakeConnection() : _incoming = StreamController<String>.broadcast();

  final StreamController<String> _incoming;
  final List<String> sent = <String>[];
  bool _closed = false;

  void inbound(String frame) => _incoming.add(frame);

  void closeRemote() {
    if (_closed) return;
    _closed = true;
    _incoming.close();
  }

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  void send(String frame) {
    sent.add(frame);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

void main() {
  group('RobotNotesWsClient', () {
    test('sends auth as the first frame within 100ms of connecting', () async {
      final conn = FakeConnection();
      final stopwatch = Stopwatch()..start();
      final client = RobotNotesWsClient(
        config: _config,
        connect: (uri) async => conn,
      );

      await client.start();
      // Drain microtasks so the auth send fires before we assert.
      await Future<void>.delayed(Duration.zero);

      expect(conn.sent, isNotEmpty);
      final first = jsonDecode(conn.sent.first) as Map<String, dynamic>;
      expect(first['type'], 'auth');
      expect(first['key'], 'test-key');
      expect(first['actor'], 'cedric');
      // Sanity: well under 100ms.
      expect(stopwatch.elapsedMilliseconds, lessThan(100));

      await client.dispose();
    });

    test('reconnects with exponential backoff after disconnect', () async {
      final connections = <FakeConnection>[];
      final delays = <Duration>[];
      var attempts = 0;

      final client = RobotNotesWsClient(
        config: _config,
        connect: (uri) async {
          attempts += 1;
          if (attempts > 4) {
            throw StateError('test wanted to stop');
          }
          final c = FakeConnection();
          connections.add(c);
          return c;
        },
        delay: (d) async {
          delays.add(d);
        },
        backoffInitial: const Duration(milliseconds: 100),
        backoffMax: const Duration(seconds: 1),
      );

      await client.start();
      await Future<void>.delayed(Duration.zero);

      // Drop the first three connections in a row to force backoff growth.
      for (var i = 0; i < 3; i++) {
        connections[i].closeRemote();
        // Let the loop notice the close, run delay, and reconnect.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }

      // Three disconnects → three backoff sleeps. Doubles each time, capped.
      expect(delays.length, greaterThanOrEqualTo(3));
      expect(delays[0], const Duration(milliseconds: 100));
      expect(delays[1], const Duration(milliseconds: 200));
      expect(delays[2], const Duration(milliseconds: 400));

      await client.dispose();
    });

    test('re-auths and re-subscribes after each reconnect', () async {
      final conns = <FakeConnection>[];
      final client = RobotNotesWsClient(
        config: _config,
        connect: (uri) async {
          final c = FakeConnection();
          conns.add(c);
          return c;
        },
        delay: (d) => Future<void>.delayed(Duration.zero),
      );

      await client.start();
      await Future<void>.delayed(Duration.zero);
      client.subscribe('01H');
      client.subscribe('02H');
      await Future<void>.delayed(Duration.zero);

      // First connection: auth + 2 subscribes.
      final firstFrames =
          conns[0].sent.map(jsonDecode).cast<Map<String, dynamic>>().toList();
      expect(firstFrames[0]['type'], 'auth');
      expect(firstFrames[1]['type'], 'subscribe');
      expect(firstFrames[2]['type'], 'subscribe');

      // Drop the connection — client should re-auth and re-subscribe.
      conns[0].closeRemote();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(conns.length, greaterThanOrEqualTo(2));
      final secondFrames =
          conns[1].sent.map(jsonDecode).cast<Map<String, dynamic>>().toList();
      expect(secondFrames.first['type'], 'auth');
      final resubs = secondFrames
          .where((m) => m['type'] == 'subscribe')
          .map((m) => m['note_id'] as String)
          .toSet();
      expect(resubs, {'01H', '02H'});

      await client.dispose();
    });

    test('inbound events surface as a typed Stream', () async {
      final conn = FakeConnection();
      final client = RobotNotesWsClient(
        config: _config,
        connect: (uri) async => conn,
      );

      final received = <RealtimeEvent>[];
      final sub = client.events.listen(received.add);
      await client.start();
      await Future<void>.delayed(Duration.zero);

      conn.inbound(
        jsonEncode(<String, Object?>{
          'type': 'presence',
          'note_id': '01H',
          'viewers': <String>['cedric', 'alice'],
        }),
      );
      conn.inbound(
        jsonEncode(<String, Object?>{
          'type': 'changed',
          'note_id': '01H',
          'version': 7,
          'by': 'alice',
          'action': 'updated',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      final messages = received.whereType<RealtimeMessage>().toList();
      expect(messages, hasLength(2));
      expect(messages[0].message, isA<PresenceEvent>());
      expect(messages[1].message, isA<ChangedEvent>());

      await sub.cancel();
      await client.dispose();
    });

    test('emits WsStale when offline duration exceeds staleThreshold',
        () async {
      // First connection succeeds; all subsequent attempts throw so the
      // client stays "offline" indefinitely. With a fake clock we step the
      // wall-clock past the stale threshold and assert the signal fires.
      var now = DateTime.utc(2025, 1, 1, 0, 0, 0);
      var attempts = 0;
      late FakeConnection initial;
      final client = RobotNotesWsClient(
        config: _config,
        connect: (uri) async {
          attempts += 1;
          if (attempts == 1) {
            initial = FakeConnection();
            return initial;
          }
          // Advance the clock 6s on each retry so the loop crosses 5s.
          now = now.add(const Duration(seconds: 6));
          throw StateError('still offline');
        },
        delay: (d) => Future<void>.delayed(Duration.zero),
        clock: () => now,
        staleThreshold: const Duration(seconds: 5),
      );

      final stale = <RealtimeEvent>[];
      final sub = client.events.where((e) => e is WsStale).listen(stale.add);

      await client.start();
      await Future<void>.delayed(Duration.zero);
      // Drop the live connection so the loop starts retrying.
      initial.closeRemote();

      // Pump the loop a few times; reconnect attempts will keep failing.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(stale, isNotEmpty);
      expect(stale.first, isA<WsStale>());

      await sub.cancel();
      await client.dispose();
    });
  });
}
