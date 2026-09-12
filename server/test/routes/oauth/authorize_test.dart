import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:test/test.dart';

import '../../../routes/oauth/authorize.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

const _apiKey = 'rn_test_key';

Config _config() => const Config(
      apiKey: _apiKey,
      dataDir: '/tmp',
      port: 8080,
      lockTtlSeconds: 60,
    );

RequestContext _ctx({
  required HttpMethod method,
  required ClientStore clientStore,
  required CodeStore codeStore,
  Map<String, String> queryParameters = const {},
  String? rawQuery,
  String? formBody,
  Config? config,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  final uri = rawQuery != null
      ? Uri.parse('http://localhost/oauth/authorize?$rawQuery')
      : Uri.parse('http://localhost/oauth/authorize').replace(
          queryParameters: queryParameters.isEmpty ? null : queryParameters,
        );
  when(() => req.uri).thenReturn(uri);
  when(() => req.headers).thenReturn(
    formBody == null
        ? const {}
        : {'content-type': 'application/x-www-form-urlencoded'},
  );
  when(req.body).thenAnswer((_) async => formBody ?? '');
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<ClientStore>()).thenReturn(clientStore);
  when(() => ctx.read<CodeStore>()).thenReturn(codeStore);
  when(() => ctx.read<Config>()).thenReturn(config ?? _config());
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-authorize-route-test-');

String _formEncode(Map<String, String> fields) => fields.entries
    .map(
      (e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}',
    )
    .join('&');

void main() {
  late Directory tmp;
  late ClientStore clientStore;
  late CodeStore codeStore;
  late RegisteredClient client;

  setUp(() async {
    tmp = _tempDir();
    final clock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
    clientStore =
        ClientStore(dir: Directory('${tmp.path}/clients'), clock: clock);
    codeStore = CodeStore(dir: Directory('${tmp.path}/codes'), clock: clock);
    client = await clientStore.register(
      clientName: 'Desk Assistant',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, String> validQuery({
    String? state,
    String? scope,
    String? resource,
  }) =>
      {
        'client_id': client.client.clientId,
        'redirect_uri': client.client.redirectUris.first,
        'response_type': 'code',
        'code_challenge': 'challenge-abc',
        'code_challenge_method': 'S256',
        if (state != null) 'state': state,
        if (scope != null) 'scope': scope,
        if (resource != null) 'resource': resource,
      };

  group('GET /oauth/authorize', () {
    test('renders the consent page for a valid request', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery(state: 'xyz'),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.body();
      expect(body, contains('Desk Assistant'));
      expect(body, contains('type="password"'));
      expect(body, contains('name="api_key"'));
      expect(body, contains('name="actor"'));
    });

    test('unregistered redirect_uri does not redirect', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery()
            ..['redirect_uri'] = 'https://not-registered.example/callback',
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      expect(res.headers.containsKey(HttpHeaders.locationHeader), isFalse);
    });

    test('a path-traversal client_id does not redirect', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery()..['client_id'] = '../../decoy',
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      expect(res.headers.containsKey(HttpHeaders.locationHeader), isFalse);
      final body = await res.body();
      expect(body, contains('<!doctype html>'));
    });

    test('unknown client_id does not redirect', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery()..['client_id'] = 'does-not-exist',
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      expect(res.headers.containsKey(HttpHeaders.locationHeader), isFalse);
    });

    test(
        'an unknown client_id and an unregistered redirect_uri render the '
        'same generic error, so the page never reveals which one was wrong',
        () async {
      final unknownClientRes = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery()..['client_id'] = 'does-not-exist',
        ),
      );
      final unregisteredRedirectRes = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery()
            ..['redirect_uri'] = 'https://not-registered.example/callback',
        ),
      );

      expect(
        await unknownClientRes.body(),
        await unregisteredRedirectRes.body(),
      );
    });

    test('missing PKCE challenge redirects with invalid_request', () async {
      final query = validQuery(state: 'xyz')..remove('code_challenge');
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: query,
        ),
      );

      expect(res.statusCode, HttpStatus.found);
      final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
      expect(location.queryParameters['error'], 'invalid_request');
      expect(location.queryParameters['state'], 'xyz');
    });

    test('wrong resource redirects with invalid_target', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery(resource: 'https://other.example/mcp'),
        ),
      );

      expect(res.statusCode, HttpStatus.found);
      final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
      expect(location.queryParameters['error'], 'invalid_target');
    });

    test('unknown scope redirects with invalid_scope', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery(scope: 'notes:read notes:admin'),
        ),
      );

      expect(res.statusCode, HttpStatus.found);
      final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
      expect(location.queryParameters['error'], 'invalid_scope');
    });

    test('a missing scope defaults to both scopes', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: validQuery(),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.body();
      expect(body, contains('name="scope" value="notes:read notes:write"'));
    });

    test(
        'a client not registered for the code response type redirects with '
        'unauthorized_client', () async {
      final restricted = await clientStore.register(
        clientName: 'No Code Response Type',
        redirectUris: ['https://restricted.example/callback'],
        tokenEndpointAuthMethod: 'none',
        grantTypes: ['authorization_code'],
        responseTypes: const [],
      );
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: {
            'client_id': restricted.client.clientId,
            'redirect_uri': restricted.client.redirectUris.first,
            'response_type': 'code',
            'code_challenge': 'challenge-abc',
            'code_challenge_method': 'S256',
            'state': 'xyz',
          },
        ),
      );

      expect(res.statusCode, HttpStatus.found);
      final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
      expect(location.queryParameters['error'], 'unauthorized_client');
      expect(location.queryParameters['state'], 'xyz');
    });

    test('a malformed percent-escape in the query renders an error page',
        () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          rawQuery: 'client_id=${client.client.clientId}&resource=%FF',
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.body();
      expect(body, contains('<!doctype html>'));
    });

    test('unsupported response_type redirects with error', () async {
      final query = validQuery(state: 'xyz')..['response_type'] = 'token';
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          clientStore: clientStore,
          codeStore: codeStore,
          queryParameters: query,
        ),
      );

      expect(res.statusCode, HttpStatus.found);
      final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
      expect(location.queryParameters['error'], 'unsupported_response_type');
    });
  });

  group('POST /oauth/authorize', () {
    test('correct key redirects with code, iss, and state', () async {
      final form = validQuery(state: 'xyz')
        ..['api_key'] = _apiKey
        ..['actor'] = 'desk-assistant';

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          clientStore: clientStore,
          codeStore: codeStore,
          formBody: _formEncode(form),
        ),
      );

      expect(res.statusCode, HttpStatus.found);
      final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
      expect(location.toString(), startsWith(client.client.redirectUris.first));
      expect(location.queryParameters['code'], isNotEmpty);
      expect(location.queryParameters['state'], 'xyz');
      expect(location.queryParameters['iss'], 'http://localhost');
    });

    test(
        'preserves a duplicate query key on the redirect_uri and encodes a '
        'space in state as %20, not +', () async {
      final withQuery = await clientStore.register(
        clientName: 'Query Client',
        redirectUris: ['https://agent.example/callback?x=1&x=2'],
        tokenEndpointAuthMethod: 'none',
        grantTypes: ['authorization_code', 'refresh_token'],
        responseTypes: ['code'],
      );
      final form = {
        'client_id': withQuery.client.clientId,
        'redirect_uri': withQuery.client.redirectUris.first,
        'response_type': 'code',
        'code_challenge': 'challenge-abc',
        'code_challenge_method': 'S256',
        'state': 'a b',
        'api_key': _apiKey,
        'actor': 'desk-assistant',
      };

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          clientStore: clientStore,
          codeStore: codeStore,
          formBody: _formEncode(form),
        ),
      );

      expect(res.statusCode, HttpStatus.found);
      final rawLocation = res.headers[HttpHeaders.locationHeader]!;
      expect(rawLocation, contains('x=1&x=2'));
      expect(rawLocation, isNot(contains('state=a+b')));
      final location = Uri.parse(rawLocation);
      expect(location.queryParametersAll['x'], ['1', '2']);
      expect(location.queryParameters['state'], 'a b');
      expect(location.queryParameters['code'], isNotEmpty);
    });

    test('a malformed percent-escape in the form body renders an error page',
        () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          clientStore: clientStore,
          codeStore: codeStore,
          formBody: 'client_id=${client.client.clientId}&resource=%FF',
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.body();
      expect(body, contains('<!doctype html>'));
    });

    test('wrong key re-renders without minting a code', () async {
      final form = validQuery()..['api_key'] = 'wrong';

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          clientStore: clientStore,
          codeStore: codeStore,
          formBody: _formEncode(form),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.containsKey(HttpHeaders.locationHeader), isFalse);
      final body = await res.body();
      expect(body, contains('class="error"'));
    });

    test('empty actor falls back to the client name', () async {
      final form = validQuery()
        ..['api_key'] = _apiKey
        ..['actor'] = '';

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          clientStore: clientStore,
          codeStore: codeStore,
          formBody: _formEncode(form),
        ),
      );

      final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
      final code = location.queryParameters['code']!;
      final record = await codeStore.consume(code, (code) async => code);
      expect(record.actor, 'Desk Assistant');
    });

    test('an omitted resource binds the code to <base>/mcp', () async {
      final form = validQuery()
        ..remove('resource')
        ..['api_key'] = _apiKey
        ..['actor'] = 'desk-assistant';

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          clientStore: clientStore,
          codeStore: codeStore,
          formBody: _formEncode(form),
        ),
      );

      expect(res.statusCode, HttpStatus.found);
      final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
      final code = location.queryParameters['code']!;
      final record = await codeStore.consume(code, (code) async => code);
      expect(record.resource, 'http://localhost/mcp');
    });

    test('consent page carries CSP and X-Frame-Options headers', () async {
      final form = validQuery()..['api_key'] = 'wrong';

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          clientStore: clientStore,
          codeStore: codeStore,
          formBody: _formEncode(form),
        ),
      );

      expect(
        res.headers['Content-Security-Policy'],
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
      );
      expect(res.headers['X-Frame-Options'], 'DENY');
    });
  });
}
