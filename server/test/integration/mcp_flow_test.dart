import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:http/http.dart' as http;
import 'package:server/src/actor_middleware.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/mcp/mcp_chain.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/static_web_middleware.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import '../../routes/mcp/index.dart' as mcp_route;
import '_oauth_test_helpers.dart';
import '_test_app.dart';

class _MutableClock implements Clock {
  _MutableClock(this._now);

  DateTime _now;

  void advance(Duration delta) => _now = _now.add(delta);

  @override
  DateTime nowUtc() => _now.toUtc();
}

/// Posts a single JSON-RPC request to `/mcp` on [app] with [accessToken] as
/// the bearer credential, and returns the decoded response body.
Future<Map<String, dynamic>> _rpc(
  TestApp app,
  String accessToken,
  String method, {
  Object id = 1,
  Map<String, Object?>? params,
}) async {
  final res = await http.post(
    Uri.parse('${app.baseUrl}/mcp'),
    headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }),
  );
  expect(res.statusCode, 200, reason: res.body);
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _callTool(
  TestApp app,
  String accessToken,
  String name,
  Map<String, Object?> arguments,
) async {
  final res = await _rpc(
    app,
    accessToken,
    'tools/call',
    params: {'name': name, 'arguments': arguments},
  );
  return res['result'] as Map<String, dynamic>;
}

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

void main() {
  group('full grant + tool calls over /mcp', () {
    late TestApp app;

    setUp(() async {
      app = await TestApp.start();
    });

    tearDown(() async {
      await app.close();
    });

    test(
      'register -> consent -> token -> initialize -> tools, broadcasting '
      'changed events under the consented actor',
      () async {
        final grant = await completeOAuthFlow(
          baseUrl: app.baseUrl,
          apiKey: app.config.apiKey,
        );

        // A wildcard WS subscriber authenticated with the static key
        // observes every `changed` event regardless of who authenticated
        // the write.
        final ch = IOWebSocketChannel.connect(Uri.parse(app.wsUrl));
        final stream = ch.stream.cast<String>().asBroadcastStream();
        addTearDown(() => ch.sink.close());
        ch.sink.add(
          jsonEncode(
            AuthMsg(key: app.config.apiKey, actor: 'watcher').toJson(),
          ),
        );
        expect(
          (jsonDecode(await stream.first) as Map<String, dynamic>)['type'],
          'auth_ok',
        );
        final events = <Map<String, dynamic>>[];
        final sub = stream.listen(
          (s) => events.add(jsonDecode(s) as Map<String, dynamic>),
        );
        addTearDown(sub.cancel);
        ch.sink.add(jsonEncode(const SubscribeMsg(noteId: '*').toJson()));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // initialize
        final initRes = await _rpc(
          app,
          grant.accessToken,
          'initialize',
          params: {'protocolVersion': '2025-06-18'},
        );
        expect(
          (initRes['result'] as Map)['protocolVersion'],
          '2025-06-18',
        );

        // tools/list
        final listRes = await _rpc(app, grant.accessToken, 'tools/list');
        final tools = (listRes['result'] as Map)['tools'] as List;
        expect(tools.length, 9);

        // create_note — sent with a spoofed X-Actor header, which MUST be
        // ignored for an OAuth-authenticated call.
        final createRes = await http.post(
          Uri.parse('${app.baseUrl}/mcp'),
          headers: {
            'Authorization': 'Bearer ${grant.accessToken}',
            'Content-Type': 'application/json',
            'X-Actor': 'spoofed',
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {
              'name': 'create_note',
              'arguments': {'title': 'Inbox', 'content': 'line one'},
            },
          }),
        );
        expect(createRes.statusCode, 200, reason: createRes.body);
        final createBody = jsonDecode(createRes.body) as Map<String, dynamic>;
        final created = (createBody['result'] as Map)['structuredContent']
            as Map<String, dynamic>;
        final noteId = created['id'] as String;

        await _waitFor(
          () => events.any(
            (e) =>
                e['type'] == 'changed' &&
                e['note_id'] == noteId &&
                e['action'] == 'created' &&
                e['by'] == 'desk-assistant',
          ),
          timeout: const Duration(seconds: 3),
        );

        // append_to_note
        final appended =
            await _callTool(app, grant.accessToken, 'append_to_note', {
          'id': noteId,
          'text': 'line two',
        });
        expect(appended['structuredContent'], containsPair('version', 2));

        // search_notes
        final searchRes = await http.post(
          Uri.parse('${app.baseUrl}/mcp'),
          headers: {
            'Authorization': 'Bearer ${grant.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': {
              'name': 'search_notes',
              'arguments': {'query': 'line'},
            },
          }),
        );
        final searchBody = jsonDecode(searchRes.body) as Map<String, dynamic>;
        final searchStructured =
            (searchBody['result'] as Map<String, dynamic>)['structuredContent']
                as Map<String, dynamic>;
        final searchItems = (searchStructured['items'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(searchItems.any((i) => i['id'] == noteId), isTrue);

        // delete_note
        final deleted = await _callTool(app, grant.accessToken, 'delete_note', {
          'id': noteId,
        });
        expect(deleted['structuredContent'], {
          'id': noteId,
          'deleted': true,
        });

        await _waitFor(
          () => events.any(
            (e) =>
                e['type'] == 'changed' &&
                e['note_id'] == noteId &&
                e['action'] == 'deleted' &&
                e['by'] == 'desk-assistant',
          ),
        );
      },
    );
  });

  group('token lifecycle', () {
    test('expired access token is rejected at /mcp', () async {
      final clock = _MutableClock(DateTime.utc(2026, 4, 25, 10));
      final app = await TestApp.start(clock: clock);
      addTearDown(app.close);

      final grant = await completeOAuthFlow(
        baseUrl: app.baseUrl,
        apiKey: app.config.apiKey,
      );
      final okRes = await http.post(
        Uri.parse('${app.baseUrl}/mcp'),
        headers: {'Authorization': 'Bearer ${grant.accessToken}'},
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      );
      expect(okRes.statusCode, 200);

      clock.advance(const Duration(hours: 2));

      final expiredRes = await http.post(
        Uri.parse('${app.baseUrl}/mcp'),
        headers: {'Authorization': 'Bearer ${grant.accessToken}'},
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      );
      expect(expiredRes.statusCode, 401);
      expect(
        expiredRes.headers['www-authenticate'],
        contains('error="invalid_token"'),
      );
    });

    test('refresh then success', () async {
      final app = await TestApp.start();
      addTearDown(app.close);

      final grant = await completeOAuthFlow(
        baseUrl: app.baseUrl,
        apiKey: app.config.apiKey,
      );
      final refreshRes = await http.post(
        Uri.parse('${app.baseUrl}/oauth/token'),
        body: {
          'grant_type': 'refresh_token',
          'client_id': grant.clientId,
          'refresh_token': grant.refreshToken,
        },
      );
      expect(refreshRes.statusCode, 200, reason: refreshRes.body);
      final refreshed = jsonDecode(refreshRes.body) as Map<String, dynamic>;
      final newAccessToken = refreshed['access_token'] as String;

      final pingRes = await http.post(
        Uri.parse('${app.baseUrl}/mcp'),
        headers: {'Authorization': 'Bearer $newAccessToken'},
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      );
      expect(pingRes.statusCode, 200, reason: pingRes.body);
    });

    test('revoke then 401', () async {
      final app = await TestApp.start();
      addTearDown(app.close);

      final grant = await completeOAuthFlow(
        baseUrl: app.baseUrl,
        apiKey: app.config.apiKey,
      );
      final revokeRes = await http.post(
        Uri.parse('${app.baseUrl}/oauth/revoke'),
        body: {'client_id': grant.clientId, 'token': grant.accessToken},
      );
      expect(revokeRes.statusCode, 200, reason: revokeRes.body);

      final pingRes = await http.post(
        Uri.parse('${app.baseUrl}/mcp'),
        headers: {'Authorization': 'Bearer ${grant.accessToken}'},
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      );
      expect(pingRes.statusCode, 401);
    });

    test(
      'access token remains valid after closing and re-bootstrapping '
      'AppDeps on the same data directory',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync(
          'robot-notes-mcp-restart-',
        );
        addTearDown(() {
          if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
        });
        // A fixed publicUrl keeps the token's bound `resource` stable
        // across the restart even though each `startTestServer` call
        // binds to a fresh ephemeral port.
        final config = Config(
          apiKey: 'restart-test-key',
          dataDir: tmpDir.path,
          port: 0,
          lockTtlSeconds: 60,
          publicUrl: 'https://notes.example.test',
        );

        var deps = await AppDeps.bootstrap(config);
        var server = await startTestServer(deps: deps, config: config);
        var baseUrl = 'http://${server.address.host}:${server.port}';

        final grant = await completeOAuthFlow(
          baseUrl: baseUrl,
          apiKey: config.apiKey,
          resource: '${config.publicUrl}/mcp',
        );

        await server.close(force: true);
        await deps.close();

        deps = await AppDeps.bootstrap(config);
        server = await startTestServer(deps: deps, config: config);
        baseUrl = 'http://${server.address.host}:${server.port}';
        addTearDown(() async {
          await server.close(force: true);
          await deps.close();
        });

        final pingRes = await http.post(
          Uri.parse('$baseUrl/mcp'),
          headers: {'Authorization': 'Bearer ${grant.accessToken}'},
          body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        );
        expect(pingRes.statusCode, 200, reason: pingRes.body);
      },
    );
  });

  group('method and auth ordering', () {
    test(
      'unauthenticated GET is 401, not 405 — auth runs before the '
      'method check',
      () async {
        final app = await TestApp.start();
        addTearDown(app.close);

        final res = await http.get(Uri.parse('${app.baseUrl}/mcp'));

        expect(res.statusCode, 401);
        expect(res.headers['www-authenticate'], contains('resource_metadata='));
      },
    );
  });

  group('static key over /mcp', () {
    test('X-Actor drives the broadcast by field', () async {
      final app = await TestApp.start();
      addTearDown(app.close);

      final ch = IOWebSocketChannel.connect(Uri.parse(app.wsUrl));
      final stream = ch.stream.cast<String>().asBroadcastStream();
      addTearDown(() => ch.sink.close());
      ch.sink.add(
        jsonEncode(
          AuthMsg(key: app.config.apiKey, actor: 'watcher').toJson(),
        ),
      );
      expect(
        (jsonDecode(await stream.first) as Map<String, dynamic>)['type'],
        'auth_ok',
      );
      final events = <Map<String, dynamic>>[];
      final sub = stream.listen(
        (s) => events.add(jsonDecode(s) as Map<String, dynamic>),
      );
      addTearDown(sub.cancel);
      ch.sink.add(jsonEncode(const SubscribeMsg(noteId: '*').toJson()));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final res = await http.post(
        Uri.parse('${app.baseUrl}/mcp'),
        headers: {
          'Authorization': 'Bearer ${app.config.apiKey}',
          'Content-Type': 'application/json',
          'X-Actor': 'research-bot',
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {
            'name': 'create_note',
            'arguments': {'title': 'Static key note'},
          },
        }),
      );
      expect(res.statusCode, 200, reason: res.body);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final noteId =
          ((body['result'] as Map)['structuredContent'] as Map)['id'] as String;

      await _waitFor(
        () => events.any(
          (e) =>
              e['type'] == 'changed' &&
              e['note_id'] == noteId &&
              e['by'] == 'research-bot',
        ),
        timeout: const Duration(seconds: 3),
      );
    });

    test('has full access to both read and write tools', () async {
      final app = await TestApp.start();
      addTearDown(app.close);

      final listRes = await http.post(
        Uri.parse('${app.baseUrl}/mcp'),
        headers: {
          'Authorization': 'Bearer ${app.config.apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'list_notes', 'arguments': <String, Object?>{}},
        }),
      );
      expect(listRes.statusCode, 200, reason: listRes.body);
      final listBody = jsonDecode(listRes.body) as Map<String, dynamic>;
      expect((listBody['result'] as Map)['isError'], isNull);

      final createRes = await http.post(
        Uri.parse('${app.baseUrl}/mcp'),
        headers: {
          'Authorization': 'Bearer ${app.config.apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'create_note',
            'arguments': {'title': 'Full access check'},
          },
        }),
      );
      expect(createRes.statusCode, 200, reason: createRes.body);
      final createBody = jsonDecode(createRes.body) as Map<String, dynamic>;
      expect((createBody['result'] as Map)['isError'], isNull);
    });
  });

  group('static mode does not shadow /mcp', () {
    test(
      'POST /mcp with a valid key returns a JSON-RPC response, not '
      'index.html',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync(
          'robot-notes-static-mcp-',
        );
        addTearDown(() {
          if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
        });
        final webDir = Directory('${tmpDir.path}/web')..createSync();
        File(
          '${webDir.path}/index.html',
        ).writeAsStringSync('<html>spa shell</html>');

        final config = Config(
          apiKey: 'static-mode-key',
          dataDir: '${tmpDir.path}/data',
          port: 0,
          lockTtlSeconds: 60,
          webDir: webDir.path,
        );
        final deps = await AppDeps.bootstrap(config);
        addTearDown(deps.close);

        // Mirrors production ordering (routes/_middleware.dart): Config
        // provider and actorIdentity (mcpAuth's static-key path reads
        // `context.read<Actor>()`) innermost, staticWebMiddleware
        // outermost so it gets first refusal on every request. `/mcp` is
        // exempt from `bearerAuth` in production, so `actorIdentity` (which
        // now consults the `RestPrincipal` `bearerAuth` provides) is fed a
        // stand-in exempt principal directly rather than wiring up the
        // whole REST auth middleware this test doesn't otherwise exercise.
        final root = Router()
          ..all('/mcp', mcpChain(mcp_route.onRequest, deps: deps));
        final pipeline = const Pipeline()
            .addMiddleware(provider<Config>((_) => config))
            .addMiddleware(
              provider<RestPrincipal>((_) => const RestPrincipal.exempt()),
            )
            .addMiddleware(actorIdentity())
            .addMiddleware(staticWebMiddleware(webDir: config.webDir))
            .addHandler(root.call);
        final server = await serve(pipeline, InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final baseUrl = 'http://${server.address.host}:${server.port}';

        final res = await http.post(
          Uri.parse('$baseUrl/mcp'),
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        );

        expect(res.statusCode, 200, reason: res.body);
        expect(res.headers['content-type'], contains('application/json'));
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        expect(json['result'], <String, dynamic>{});

        // An unauthenticated GET (no file extension, so it would otherwise
        // look like an SPA route) must still reach mcpAuth and get 401 —
        // not the SPA shell's index.html — proving /mcp is excluded from
        // static serving rather than merely bypassing it because this
        // particular request happened to be a POST.
        final getRes = await http.get(Uri.parse('$baseUrl/mcp'));
        expect(getRes.statusCode, 401);
        expect(getRes.body, isNot(contains('spa shell')));
      },
    );
  });
}
