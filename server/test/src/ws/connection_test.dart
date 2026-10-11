// `handleMessage` returns `Future<void>` because the auth path may need an
// async OAuth-token lookup, but every call below that doesn't `await` it
// either supplies the static key (a synchronous fast path with no `await`
// inside it) or is a post-auth/pre-auth message (handled fully
// synchronously) — so the side effects the assertions check already
// happened by the time the call returns.
// ignore_for_file: unawaited_futures

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_otel_api/dart_otel_api.dart';
import 'package:dart_otel_sdk/dart_otel_sdk.dart' show SdkTracer;
import 'package:fake_async/fake_async.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/connection.dart';
import 'package:server/src/ws/presence.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../../knowledge_test_context.dart' as knowledge_fixture;
import '../otel/_span_test_helpers.dart';

const _restResource = 'http://localhost';

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
  late Directory tmp;
  late TokenStore tokenStore;
  const apiKey = 'rn_test';

  knowledge_fixture.authorizedSetUp(() {
    broadcaster = Broadcaster();
    presence = PresenceTracker();
    tmp = Directory.systemTemp.createTempSync('robot-notes-ws-conn-test-');
    tokenStore = TokenStore(dir: Directory('${tmp.path}/tokens'));
  });

  tearDown(() async {
    await broadcaster.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  WsConnection makeConn(
    String id, {
    required _FakeSink sink,
    Duration authTimeout = const Duration(seconds: 2),
    TokenStore? tokenStoreOverride,
  }) {
    return WsConnection(
      id: id,
      authorization: knowledge_fixture.fixtureAuthorization,
      resolveKnowledgeTarget: (id) async => KnowledgeTarget.note(id, ''),
      sink: sink,
      broadcaster: broadcaster,
      presence: presence,
      apiKey: apiKey,
      tokenStore: tokenStoreOverride ?? tokenStore,
      restResource: _restResource,
      authTimeout: authTimeout,
    );
  }

  group('auth handshake', () {
    knowledge_fixture.authorizedTest(
        'connection without auth within timeout closes 4001 auth_timeout', () {
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

    knowledge_fixture.authorizedTest(
        'auth with wrong key closes 4001 auth_failed', () async {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)..start();
      await conn.handleMessage(jsonEncode({'type': 'auth', 'key': 'nope'}));
      expect(sink.closes, hasLength(1));
      expect(sink.closes.single.code, 4001);
      expect(sink.closes.single.reason, 'auth_failed');
    });

    knowledge_fixture
        .authorizedTest('successful auth sends auth_ok and binds actor', () {
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

    knowledge_fixture
        .authorizedTest('auth without "actor" defaults to "unknown"', () {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}));
      expect(conn.actor!.name, 'unknown');
    });

    knowledge_fixture.authorizedTest('successful auth cancels the auth timer',
        () {
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

    group('OAuth access tokens', () {
      Future<String> issueToken({
        Set<String> scopes = const {'notes:read'},
        String resource = _restResource,
        String actor = 'Alice Example',
      }) async {
        final issued = await tokenStore.issue(
          clientId: 'client-1',
          actor: actor,
          scopes: scopes,
          resource: resource,
          grantId: 'grant-1',
        );
        return issued.accessToken;
      }

      knowledge_fixture.authorizedTest(
          'a REST-audience token with notes:read authenticates and binds '
          'the recorded actor', () async {
        final token = await issueToken();
        final sink = _FakeSink();
        final conn = makeConn('c1', sink: sink)..start();
        await conn.handleMessage(jsonEncode({'type': 'auth', 'key': token}));

        expect(conn.isAuthed, isTrue);
        expect(conn.actor!.name, 'Alice Example');
        expect(sink.closes, isEmpty);
        expect(_decode(sink.sent.single)['type'], 'auth_ok');
      });

      knowledge_fixture.authorizedTest('an MCP-audience token is rejected',
          () async {
        final token = await issueToken(resource: '$_restResource/mcp');
        final sink = _FakeSink();
        final conn = makeConn('c1', sink: sink)..start();
        await conn.handleMessage(jsonEncode({'type': 'auth', 'key': token}));

        expect(sink.closes, hasLength(1));
        expect(sink.closes.single.code, 4001);
        expect(sink.closes.single.reason, 'auth_failed');
      });

      knowledge_fixture.authorizedTest('a token lacking notes:read is rejected',
          () async {
        final token = await issueToken(scopes: {'notes:write'});
        final sink = _FakeSink();
        final conn = makeConn('c1', sink: sink)..start();
        await conn.handleMessage(jsonEncode({'type': 'auth', 'key': token}));

        expect(sink.closes, hasLength(1));
        expect(sink.closes.single.code, 4001);
        expect(sink.closes.single.reason, 'auth_failed');
      });

      knowledge_fixture.authorizedTest(
          'a connection closed while the token lookup is pending does not '
          'complete auth afterwards', () async {
        final token = await issueToken();
        final sink = _FakeSink();
        final conn = makeConn('c1', sink: sink)..start();

        final authFuture = conn.handleMessage(
          jsonEncode({'type': 'auth', 'key': token}),
        );
        // The client disconnects (or the auth timer fires) while the async
        // token-store lookup above is still pending.
        await conn.handleDone();
        await authFuture;

        expect(conn.isAuthed, isFalse);
        expect(sink.sent, isEmpty);
        expect(broadcaster.isRegistered('c1'), isFalse);
      });
    });
  });

  group('pre-auth message handling', () {
    knowledge_fixture
        .authorizedTest('subscribe before auth is silently ignored', () async {
      final sink = _FakeSink();
      makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'n1'}));
      broadcaster.emitLock(const LockEvent(noteId: 'n1', holder: 'alice'));
      await Future<void>.delayed(Duration.zero);
      expect(sink.sent, isEmpty);
      expect(broadcaster.isRegistered('c1'), isFalse);
    });

    knowledge_fixture.authorizedTest('ping before auth is silently ignored',
        () {
      final sink = _FakeSink();
      makeConn('c1', sink: sink)
        ..start()
        ..handleMessage(jsonEncode({'type': 'ping', 'id': 'x'}));
      expect(sink.sent, isEmpty);
    });

    knowledge_fixture
        .authorizedTest('unknown message before auth is silently ignored', () {
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

    knowledge_fixture.authorizedTest(
        'per-note subscribe forwards events for that note only', () async {
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

    knowledge_fixture.authorizedTest(
        'wildcard subscribe forwards events for any note', () async {
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

    knowledge_fixture.authorizedTest(
        'unsubscribe stops further delivery for that note', () async {
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

    knowledge_fixture.authorizedTest(
        'subscribing fans out a presence event to existing viewers', () async {
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

    knowledge_fixture.authorizedTest(
        'disconnecting removes the actor from presence', () async {
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

    knowledge_fixture.authorizedTest(
        'same actor on two connections appears once in presence', () async {
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
    knowledge_fixture.authorizedTest(
        'lock event propagates to subscribed connection', () async {
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

    knowledge_fixture.authorizedTest('changed event does NOT include content',
        () async {
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
    knowledge_fixture.authorizedTest('ping is echoed with the same id', () {
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
    knowledge_fixture
        .authorizedTest('binary frame closes 1003 unsupported_data', () {
      final sink = _FakeSink();
      final conn = makeConn('c1', sink: sink)
        ..start()
        ..handleMessage([0x01, 0x02, 0x03]);
      expect(conn.isClosed, isTrue);
      expect(sink.closes.single.code, 1003);
    });

    knowledge_fixture.authorizedTest(
        'unknown message type after auth surfaces as error envelope', () async {
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

    knowledge_fixture.authorizedTest(
        'malformed JSON after auth surfaces as error envelope', () async {
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

  group('tracing', () {
    knowledge_fixture.authorizedTest(
        'a message is traced as a root span linked to the connection span, '
        'not nested under an ambient span', () async {
      final processor = RecordingProcessor();
      final tracer =
          SdkTracer(name: 'test', version: null, processor: processor);
      const connectionContext = SpanContext(
        traceId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        spanId: 'bbbbbbbbbbbbbbbb',
      );
      final sink = _FakeSink();
      final conn = WsConnection(
        id: 'c1',
        sink: sink,
        broadcaster: broadcaster,
        presence: presence,
        apiKey: apiKey,
        tokenStore: tokenStore,
        restResource: _restResource,
        tracer: tracer,
        connectionSpanContext: connectionContext,
      )..start();

      // Simulates the WS upgrade request's span still being ambient in this
      // callback's zone, the way it would be if the socket's message loop
      // ran inside otelHttpTraceMiddleware's Span.runWithSpan zone.
      final ambientSpan = tracer.startSpan('ambient', kind: SpanKind.server);
      await Span.runWithSpan(
        ambientSpan,
        () => conn.handleMessage(jsonEncode({'type': 'auth', 'key': apiKey})),
      );
      ambientSpan.end();

      final messageSpan =
          processor.ended.firstWhere((d) => d.name == 'ws.message.auth');
      expect(messageSpan.parentSpanId, isNull);
      expect(
        messageSpan.spanContext.traceId,
        isNot(ambientSpan.spanContext.traceId),
      );
      expect(messageSpan.spanContext.traceId, isNot(connectionContext.traceId));
      expect(messageSpan.links, hasLength(1));
      expect(messageSpan.links.single.context, connectionContext);
      expect(messageSpan.attributes['ws.connection.id'], 'c1');
    });

    knowledge_fixture.authorizedTest(
        'a message span carries no links when connectionSpanContext is null',
        () async {
      final processor = RecordingProcessor();
      final tracer =
          SdkTracer(name: 'test', version: null, processor: processor);
      final sink = _FakeSink();
      final conn = WsConnection(
        id: 'c1',
        sink: sink,
        broadcaster: broadcaster,
        presence: presence,
        apiKey: apiKey,
        tokenStore: tokenStore,
        restResource: _restResource,
        tracer: tracer,
      )..start();

      await conn.handleMessage(jsonEncode({'type': 'auth', 'key': apiKey}));

      final messageSpan = processor.ended.single;
      expect(messageSpan.links, isEmpty);
    });
  });

  group('disconnect cleanup', () {
    knowledge_fixture.authorizedTest(
        'handleDone clears presence and broadcaster registration', () async {
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
  knowledge_fixture.authorizedTest(
      'scoped subscriptions and wildcard events respect current note ACLs',
      () async {
    final authorization =
        NoteAuthorizationService(store: KnowledgePolicyStore.memory());
    addTearDown(authorization.store.dispose);
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'private',
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    final tokens = await tokenStore.issue(
      clientId: 'viewer',
      resource: _restResource,
      scopes: {'notes:read'},
      actor: 'viewer',
      grantId: 'viewer',
    );
    final sink = _FakeSink();
    final conn = WsConnection(
      id: 'scoped',
      sink: sink,
      broadcaster: broadcaster,
      presence: presence,
      apiKey: apiKey,
      tokenStore: tokenStore,
      restResource: _restResource,
      authorization: authorization,
      resolveKnowledgeTarget: (id) async =>
          KnowledgeTarget.note(id, id == 'secret' ? 'private' : 'public'),
    )..start();
    await conn.handleMessage(
      jsonEncode(
        {'type': 'auth', 'key': tokens.accessToken, 'actor': 'operator'},
      ),
    );
    await conn
        .handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'secret'}));
    expect(presence.viewersOf('secret'), isEmpty);
    expect(
      sink.sent.any((raw) => raw.contains('knowledge_access_denied')),
      true,
    );
    await conn.handleMessage(jsonEncode({'type': 'subscribe', 'note_id': '*'}));
    broadcaster
      ..emitChanged(
        const ChangedEvent(
          noteId: 'secret',
          version: 1,
          by: 'human',
          action: ChangeAction.updated,
        ),
      )
      ..emitChanged(
        const ChangedEvent(
          noteId: 'visible',
          version: 1,
          by: 'human',
          action: ChangeAction.updated,
        ),
      );
    await Future<void>.delayed(Duration.zero);
    expect(sink.sent.any((raw) => raw.contains('"note_id":"secret"')), false);
    expect(sink.sent.any((raw) => raw.contains('"note_id":"visible"')), true);
    await conn
        .handleMessage(jsonEncode({'type': 'subscribe', 'note_id': 'visible'}));
    expect(presence.viewersOf('visible'), contains('viewer'));
    await authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'public',
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    expect(conn.isClosed, true);
    expect(presence.viewersOf('visible'), isEmpty);
    await conn.handleDone();
  });
}
