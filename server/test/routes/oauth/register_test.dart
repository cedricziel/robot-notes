import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:test/test.dart';

import '../../../routes/oauth/register.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required ClientStore store,
  Object? body,
  String? rawBody,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.headers).thenReturn(const {});
  when(req.body).thenAnswer((_) async => rawBody ?? jsonEncode(body));
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<ClientStore>()).thenReturn(store);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-register-route-test-');

void main() {
  late Directory tmp;
  late ClientStore store;

  setUp(() {
    tmp = _tempDir();
    store = ClientStore(
      dir: Directory('${tmp.path}/clients'),
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('mints a public client with no client_secret', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Desk Assistant',
          'redirect_uris': ['https://agent.example/callback'],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.created);
    expect(res.headers['Cache-Control'], 'no-store');
    final json = await res.json() as Map<String, dynamic>;
    expect(json['client_id'], isNotEmpty);
    expect(json['token_endpoint_auth_method'], 'none');
    expect(json.containsKey('client_secret'), isFalse);
  });

  test('mints a confidential client with a client_secret', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Server Agent',
          'redirect_uris': ['https://agent.example/callback'],
          'token_endpoint_auth_method': 'client_secret_post',
        },
      ),
    );

    expect(res.statusCode, HttpStatus.created);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['client_secret'], isNotEmpty);
    expect(json['client_secret_expires_at'], 0);
  });

  test('allows a localhost http redirect URI', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Local dev',
          'redirect_uris': ['http://localhost:53421/callback'],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.created);
  });

  test('rejects a plain http redirect URI', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Bad',
          'redirect_uris': ['http://agent.example/callback'],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_redirect_uri');
  });

  test('rejects a missing redirect_uris', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {'client_name': 'x'},
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_redirect_uri');
  });

  test('rejects a client_name longer than 256 characters', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'x' * 257,
          'redirect_uris': ['https://agent.example/callback'],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_client_metadata');
  });

  test('accepts a client_name of exactly 256 characters', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'x' * 256,
          'redirect_uris': ['https://agent.example/callback'],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.created);
  });

  test('rejects more than 10 redirect_uris', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Too Many',
          'redirect_uris': [
            for (var i = 0; i < 11; i++) 'https://agent.example/cb$i',
          ],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_client_metadata');
  });

  test('accepts exactly 10 redirect_uris', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Exactly Ten',
          'redirect_uris': [
            for (var i = 0; i < 10; i++) 'https://agent.example/cb$i',
          ],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.created);
  });

  test('rejects a redirect_uri longer than 2048 characters', () async {
    final longPath = 'a' * 2040;
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Long URI',
          'redirect_uris': ['https://agent.example/$longPath'],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_client_metadata');
  });

  test('rejects a redirect_uri carrying a fragment', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Fragment',
          'redirect_uris': ['https://agent.example/callback#fragment'],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_redirect_uri');
  });

  test('defaults client_name to mcp-client when absent', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'redirect_uris': ['https://agent.example/callback'],
        },
      ),
    );

    expect(res.statusCode, HttpStatus.created);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['client_name'], 'mcp-client');
  });

  test('rejects an unsupported token_endpoint_auth_method', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'x',
          'redirect_uris': ['https://agent.example/callback'],
          'token_endpoint_auth_method': 'private_key_jwt',
        },
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_client_metadata');
  });

  test('accepts a body of exactly 16 KiB', () async {
    final base = {
      'client_name': 'Padded',
      'redirect_uris': ['https://agent.example/callback'],
      'padding': '',
    };
    final baseLength = jsonEncode(base).length;
    final padded = {...base, 'padding': 'a' * (16 * 1024 - baseLength)};
    expect(jsonEncode(padded).length, 16 * 1024);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, store: store, body: padded),
    );

    expect(res.statusCode, HttpStatus.created);
  });

  test('rejects a body larger than 16 KiB', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        rawBody: 'x' * (16 * 1024 + 1),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_client_metadata');
  });

  test('GET is not allowed', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, store: store),
    );

    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });

  test('persists the registration so it survives restart', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        store: store,
        body: {
          'client_name': 'Persisted',
          'redirect_uris': ['https://agent.example/callback'],
        },
      ),
    );
    final json = await res.json() as Map<String, dynamic>;
    final reopened = ClientStore(dir: Directory('${tmp.path}/clients'));
    final reloaded = await reopened.get(json['client_id'] as String);
    expect(reloaded, isNotNull);
    expect(reloaded!.clientName, 'Persisted');
  });
}
