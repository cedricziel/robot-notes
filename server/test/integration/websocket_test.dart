import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import '_test_app.dart';

/// Two real WebSocket clients negotiate the in-protocol handshake, subscribe
/// to a note (or wildcard), and observe each other's presence and `changed`
/// events when one of them creates and updates a note over HTTP.
void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.start();
  });

  tearDown(() async {
    await app.close();
  });

  test("two clients see each other's presence and changes", () async {
    // 1. Alice creates a note over HTTP so we have a known noteId.
    final createRes = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(actor: 'alice'),
      body: jsonEncode({'title': 'shared', 'content': 'before'}),
    );
    expect(createRes.statusCode, 201);
    final id =
        (jsonDecode(createRes.body) as Map<String, dynamic>)['id'] as String;

    // 2. Connect Alice and Bob to /ws.
    final aliceCh = IOWebSocketChannel.connect(Uri.parse(app.wsUrl));
    final aliceStream = aliceCh.stream.cast<String>().asBroadcastStream();
    final bobCh = IOWebSocketChannel.connect(Uri.parse(app.wsUrl));
    final bobStream = bobCh.stream.cast<String>().asBroadcastStream();
    addTearDown(() async {
      await aliceCh.sink.close();
      await bobCh.sink.close();
    });

    // 3. Both authenticate.
    aliceCh.sink.add(
      jsonEncode(AuthMsg(key: app.config.apiKey, actor: 'alice').toJson()),
    );
    bobCh.sink.add(
      jsonEncode(AuthMsg(key: app.config.apiKey, actor: 'bob').toJson()),
    );

    final aliceFirst = await aliceStream.first;
    final bobFirst = await bobStream.first;
    expect((jsonDecode(aliceFirst) as Map<String, dynamic>)['type'], 'auth_ok');
    expect((jsonDecode(bobFirst) as Map<String, dynamic>)['type'], 'auth_ok');

    // 4. Alice subscribes to the note. Bob subscribes to the same note —
    //    Bob's subscribe should produce a presence event Alice can see.
    final aliceMessages = <Map<String, dynamic>>[];
    final aliceSub = aliceStream.listen(
      (s) => aliceMessages.add(jsonDecode(s) as Map<String, dynamic>),
    );
    final bobMessages = <Map<String, dynamic>>[];
    final bobSub = bobStream.listen(
      (s) => bobMessages.add(jsonDecode(s) as Map<String, dynamic>),
    );
    addTearDown(() async {
      await aliceSub.cancel();
      await bobSub.cancel();
    });

    aliceCh.sink.add(jsonEncode(SubscribeMsg(noteId: id).toJson()));
    // Give the broadcaster a tick to register Alice before Bob arrives.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    bobCh.sink.add(jsonEncode(SubscribeMsg(noteId: id).toJson()));

    // 5. Wait for Alice to observe a presence event listing both viewers.
    await _waitFor(() {
      return aliceMessages.any((m) {
        if (m['type'] != 'presence') return false;
        final viewers = (m['viewers'] as List).cast<String>();
        return viewers.contains('alice') && viewers.contains('bob');
      });
    });

    // 6. Bob updates the note via HTTP. Both clients should receive a
    //    `changed` event for that noteId at version 2.
    final updateRes = await http.put(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: {
        ...app.headers(actor: 'bob'),
        'If-Match': '1',
      },
      body: jsonEncode({'title': 'shared', 'content': 'after'}),
    );
    expect(updateRes.statusCode, 200, reason: updateRes.body);

    await _waitFor(() {
      return aliceMessages.any(
        (m) =>
            m['type'] == 'changed' && m['note_id'] == id && m['version'] == 2,
      );
    });
    await _waitFor(() {
      return bobMessages.any(
        (m) =>
            m['type'] == 'changed' && m['note_id'] == id && m['version'] == 2,
      );
    });

    final aliceChanged = aliceMessages.firstWhere(
      (m) => m['type'] == 'changed',
    );
    expect(aliceChanged['by'], 'bob');
    expect(aliceChanged['action'], 'updated');
    expect(
      aliceChanged.containsKey('content'),
      isFalse,
      reason: 'changed events MUST NOT carry content',
    );
  });

  test('wildcard subscriber sees changes for any note', () async {
    final ch = IOWebSocketChannel.connect(Uri.parse(app.wsUrl));
    final stream = ch.stream.cast<String>().asBroadcastStream();
    addTearDown(() => ch.sink.close());

    ch.sink.add(
      jsonEncode(AuthMsg(key: app.config.apiKey, actor: 'watcher').toJson()),
    );
    final firstRaw = await stream.first;
    expect(
      (jsonDecode(firstRaw) as Map<String, dynamic>)['type'],
      'auth_ok',
    );

    final messages = <Map<String, dynamic>>[];
    final sub = stream.listen(
      (s) => messages.add(jsonDecode(s) as Map<String, dynamic>),
    );
    addTearDown(sub.cancel);

    // Wildcard subscribe.
    ch.sink.add(jsonEncode(const SubscribeMsg(noteId: '*').toJson()));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Create a note over HTTP — wildcard listener should see `changed:created`.
    final createRes = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(actor: 'someone-else'),
      body: jsonEncode({'title': 'broadcast me', 'content': ''}),
    );
    expect(createRes.statusCode, 201);

    await _waitFor(
      () => messages.any(
        (m) => m['type'] == 'changed' && m['action'] == 'created',
      ),
    );
  });
}

/// Polls [predicate] until it returns true or [timeout] elapses, throwing a
/// helpful [TimeoutException] otherwise. Integration WS tests are
/// inherently asynchronous, so all assertions on received frames go
/// through this helper instead of [Future.delayed]+expect.
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(step);
  }
  if (!predicate()) {
    throw TimeoutException('predicate did not become true in $timeout');
  }
}
