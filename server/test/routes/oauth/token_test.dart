import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/pkce.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:test/test.dart';

import '../../../routes/oauth/token.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required ClientStore clientStore,
  required CodeStore codeStore,
  required TokenStore tokenStore,
  String? formBody,
  Map<String, String> headers = const {},
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(HttpMethod.post);
  final lower = {
    'content-type': 'application/x-www-form-urlencoded',
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(req.body).thenAnswer((_) async => formBody ?? '');
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<ClientStore>()).thenReturn(clientStore);
  when(() => ctx.read<CodeStore>()).thenReturn(codeStore);
  when(() => ctx.read<TokenStore>()).thenReturn(tokenStore);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-token-route-test-');

String _formEncode(Map<String, String> fields) => fields.entries
    .map(
      (e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}',
    )
    .join('&');

const _resource = 'http://localhost/mcp';
const _verifier = 'a-code-verifier-that-is-long-enough-1234567890';

/// A [Clock] that returns the same instant until explicitly [advance]d,
/// so tests can mint a code/token at one instant and then jump forward to
/// exercise expiry without depending on how many times a store under test
/// happens to read the clock.
class _MutableClock implements Clock {
  _MutableClock(this._now);
  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

/// A [TokenStore] that mints a real token pair and then throws, simulating
/// a downstream failure (e.g. a broken filesystem) after the grant has
/// already been half-issued. [lastIssued] captures what was minted so a
/// test can confirm it was rolled back.
class _ThrowingAfterIssueTokenStore extends TokenStore {
  _ThrowingAfterIssueTokenStore({required super.dir, required super.clock});

  IssuedTokens? lastIssued;

  @override
  Future<IssuedTokens> issue({
    required String clientId,
    required String actor,
    required Set<String> scopes,
    required String resource,
    required String grantId,
    bool withRefresh = true,
  }) async {
    lastIssued = await super.issue(
      clientId: clientId,
      actor: actor,
      scopes: scopes,
      resource: resource,
      grantId: grantId,
      withRefresh: withRefresh,
    );
    throw StateError('simulated downstream failure after token issuance');
  }
}

void main() {
  late Directory tmp;
  late ClientStore clientStore;
  late CodeStore codeStore;
  late TokenStore tokenStore;
  late _MutableClock clock;

  setUp(() {
    tmp = _tempDir();
    clock = _MutableClock(DateTime.utc(2026, 4, 25, 10));
    clientStore =
        ClientStore(dir: Directory('${tmp.path}/clients'), clock: clock);
    codeStore = CodeStore(dir: Directory('${tmp.path}/codes'), clock: clock);
    tokenStore = TokenStore(dir: Directory('${tmp.path}/tokens'), clock: clock);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<RegisteredClient> registerPublic() => clientStore.register(
        clientName: 'Public',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'none',
        grantTypes: ['authorization_code', 'refresh_token'],
        responseTypes: ['code'],
      );

  Future<String> mintCode(
    RegisteredClient client, {
    String grantId = 'grant-1',
    String redirectUri = 'https://agent.example/callback',
    Set<String> scopes = const {'notes:read', 'notes:write'},
  }) =>
      codeStore.mint(
        clientId: client.client.clientId,
        redirectUri: redirectUri,
        codeChallenge: pkceS256Challenge(_verifier),
        scopes: scopes,
        resource: _resource,
        actor: 'desk-assistant',
        grantId: grantId,
      );

  group('grant_type=authorization_code', () {
    test('successful exchange', () async {
      final client = await registerPublic();
      final code = await mintCode(client);

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers['Cache-Control'], 'no-store');
      final json = await res.json() as Map<String, dynamic>;
      expect(json['token_type'], 'Bearer');
      expect(json['expires_in'], 3600);
      expect(json['refresh_token'], isNotEmpty);
      expect(json['scope'], 'notes:read notes:write');
      expect(json['actor'], 'desk-assistant');
    });

    test('actor reflects the grant recorded actor from a custom mint',
        () async {
      final client = await registerPublic();
      final code = await codeStore.mint(
        clientId: client.client.clientId,
        redirectUri: 'https://agent.example/callback',
        codeChallenge: pkceS256Challenge(_verifier),
        scopes: const {'notes:read', 'notes:write'},
        resource: _resource,
        actor: 'Alice Example',
        grantId: 'grant-actor-test',
      );

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );

      final json = await res.json() as Map<String, dynamic>;
      expect(json['actor'], 'Alice Example');
    });

    test('wrong verifier is rejected', () async {
      final client = await registerPublic();
      final code = await mintCode(client);

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': 'wrong-verifier',
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['error'], 'invalid_grant');
    });

    test('code reuse revokes the grant', () async {
      final client = await registerPublic();
      final code = await mintCode(client);
      final form = _formEncode({
        'grant_type': 'authorization_code',
        'client_id': client.client.clientId,
        'code': code,
        'redirect_uri': 'https://agent.example/callback',
        'code_verifier': _verifier,
      });

      final first = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: form,
        ),
      );
      final firstJson = await first.json() as Map<String, dynamic>;
      final accessToken = firstJson['access_token'] as String;

      final second = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: form,
        ),
      );
      expect(second.statusCode, HttpStatus.badRequest);
      final secondJson = await second.json() as Map<String, dynamic>;
      expect(secondJson['error'], 'invalid_grant');

      final lookup = await tokenStore.lookupAccess(accessToken);
      expect(lookup, isNull);
    });

    test(
        'a non-OAuth exception from TokenStore.issue revokes the grant and '
        'maps to a 500 server_error, without exposing the raw error', () async {
      final client = await registerPublic();
      final code = await mintCode(client);
      final throwingStore = _ThrowingAfterIssueTokenStore(
        dir: Directory('${tmp.path}/tokens'),
        clock: clock,
      );

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: throwingStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.internalServerError);
      final json = await res.json() as Map<String, dynamic>;
      expect(json, {'error': 'server_error'});

      final issued = throwingStore.lastIssued!;
      final lookup = await throwingStore.lookupAccess(issued.accessToken);
      expect(
        lookup,
        isNull,
        reason: 'the half-issued grant must be revoked, not left live',
      );
    });

    test(
        'a concurrent replay of the same code yields exactly one success '
        'and the winning grant is revoked', () async {
      final client = await registerPublic();
      final code = await mintCode(client);
      final form = _formEncode({
        'grant_type': 'authorization_code',
        'client_id': client.client.clientId,
        'code': code,
        'redirect_uri': 'https://agent.example/callback',
        'code_verifier': _verifier,
      });

      final results = await Future.wait([
        route.onRequest(
          _ctx(
            clientStore: clientStore,
            codeStore: codeStore,
            tokenStore: tokenStore,
            formBody: form,
          ),
        ),
        route.onRequest(
          _ctx(
            clientStore: clientStore,
            codeStore: codeStore,
            tokenStore: tokenStore,
            formBody: form,
          ),
        ),
      ]);

      final statuses = results.map((r) => r.statusCode).toList()..sort();
      expect(statuses, [HttpStatus.ok, HttpStatus.badRequest]);

      final success = results.singleWhere(
        (r) => r.statusCode == HttpStatus.ok,
      );
      final failure = results.singleWhere(
        (r) => r.statusCode == HttpStatus.badRequest,
      );
      final failureJson = await failure.json() as Map<String, dynamic>;
      expect(failureJson['error'], 'invalid_grant');

      final successJson = await success.json() as Map<String, dynamic>;
      final accessToken = successJson['access_token'] as String;
      final lookup = await tokenStore.lookupAccess(accessToken);
      expect(
        lookup,
        isNull,
        reason: "the winning exchange's tokens must be revoked once the "
            'replay is detected, even though they were already issued',
      );
    });

    test('expired code is rejected', () async {
      final client = await registerPublic();
      final code = await mintCode(client);
      clock.advance(const Duration(minutes: 11));

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['error'], 'invalid_grant');
    });

    test('wrong redirect_uri is rejected', () async {
      final client = await registerPublic();
      final code = await mintCode(client);

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'code': code,
            'redirect_uri': 'https://different.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['error'], 'invalid_grant');
    });

    test('wrong client is rejected', () async {
      final client = await registerPublic();
      final otherClient = await clientStore.register(
        clientName: 'Other',
        redirectUris: ['https://other.example/callback'],
        tokenEndpointAuthMethod: 'none',
        grantTypes: ['authorization_code', 'refresh_token'],
        responseTypes: ['code'],
      );
      final code = await mintCode(client);

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': otherClient.client.clientId,
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['error'], 'invalid_grant');
    });

    test('confidential client with wrong secret is 401', () async {
      final client = await clientStore.register(
        clientName: 'Confidential',
        redirectUris: ['https://agent.example/callback'],
        tokenEndpointAuthMethod: 'client_secret_post',
        grantTypes: ['authorization_code', 'refresh_token'],
        responseTypes: ['code'],
      );
      final code = await mintCode(client);

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'client_secret': 'wrong-secret',
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.unauthorized);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['error'], 'invalid_client');
    });

    test('missing parameters are rejected', () async {
      final client = await registerPublic();

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['error'], 'invalid_request');
    });
  });

  test('a malformed percent-escape in the form body is invalid_request',
      () async {
    final client = await registerPublic();
    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: 'grant_type=authorization_code'
            '&client_id=${client.client.clientId}'
            '&code=%FF',
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_request');
  });

  test(
      'client authentication is checked before grant_type, so an unknown '
      'client with a missing grant_type is 401 invalid_client, not 400',
      () async {
    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: _formEncode({'client_id': 'does-not-exist'}),
      ),
    );

    expect(res.statusCode, HttpStatus.unauthorized);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_client');
  });

  test(
      'client authentication is checked before grant_type, so an unknown '
      'client with an unsupported grant_type is still 401 invalid_client',
      () async {
    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'client_id': 'does-not-exist',
          'grant_type': 'password',
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.unauthorized);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_client');
  });

  test('unsupported grant type', () async {
    final client = await registerPublic();
    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'grant_type': 'password',
          'client_id': client.client.clientId,
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'unsupported_grant_type');
  });

  test('a missing grant_type is invalid_request', () async {
    final client = await registerPublic();

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: _formEncode({'client_id': client.client.clientId}),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_request');
  });

  test('a client not registered for authorization_code is unauthorized_client',
      () async {
    final client = await clientStore.register(
      clientName: 'Refresh Only',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['refresh_token'],
      responseTypes: ['code'],
    );
    final code = await mintCode(client);

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'grant_type': 'authorization_code',
          'client_id': client.client.clientId,
          'code': code,
          'redirect_uri': 'https://agent.example/callback',
          'code_verifier': _verifier,
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'unauthorized_client');
  });

  test('a client without the refresh_token grant gets no refresh_token',
      () async {
    final client = await clientStore.register(
      clientName: 'Code Only',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code'],
      responseTypes: ['code'],
    );
    final code = await mintCode(client);

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'grant_type': 'authorization_code',
          'client_id': client.client.clientId,
          'code': code,
          'redirect_uri': 'https://agent.example/callback',
          'code_verifier': _verifier,
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.ok);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['access_token'], isNotEmpty);
    expect(json.containsKey('refresh_token'), isFalse);
  });

  test(
      'a client without the refresh_token grant never gets a refresh token '
      'minted for it, not just one withheld from the response', () async {
    final client = await clientStore.register(
      clientName: 'Code Only',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code'],
      responseTypes: ['code'],
    );
    final code = await mintCode(client);

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'grant_type': 'authorization_code',
          'client_id': client.client.clientId,
          'code': code,
          'redirect_uri': 'https://agent.example/callback',
          'code_verifier': _verifier,
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.ok);
    final tokenFiles =
        Directory('${tmp.path}/tokens').listSync().whereType<File>().toList();
    expect(
      tokenFiles,
      hasLength(1),
      reason: 'only the access token should ever be persisted',
    );
  });

  test('a client not registered for refresh_token is unauthorized_client',
      () async {
    final client = await clientStore.register(
      clientName: 'Code Only',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code'],
      responseTypes: ['code'],
    );
    final issued = await tokenStore.issue(
      clientId: client.client.clientId,
      actor: 'desk-assistant',
      scopes: const {'notes:read', 'notes:write'},
      resource: _resource,
      grantId: 'grant-1',
    );

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        codeStore: codeStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'grant_type': 'refresh_token',
          'client_id': client.client.clientId,
          'refresh_token': issued.refreshToken!,
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'unauthorized_client');
  });

  group('grant_type=refresh_token', () {
    Future<Map<String, dynamic>> exchange(RegisteredClient client) async {
      final code = await mintCode(client);
      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );
      return await res.json() as Map<String, dynamic>;
    }

    test('rotates the refresh token', () async {
      final client = await registerPublic();
      final first = await exchange(client);

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'refresh_token',
            'client_id': client.client.clientId,
            'refresh_token': first['refresh_token'] as String,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['access_token'], isNot(first['access_token']));
      expect(json['refresh_token'], isNot(first['refresh_token']));
      expect(json['actor'], 'desk-assistant');

      final reused = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'refresh_token',
            'client_id': client.client.clientId,
            'refresh_token': first['refresh_token'] as String,
          }),
        ),
      );
      expect(reused.statusCode, HttpStatus.badRequest);
    });

    test('rotated token reuse revokes the family', () async {
      final client = await registerPublic();
      final first = await exchange(client);

      final rotated = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'refresh_token',
            'client_id': client.client.clientId,
            'refresh_token': first['refresh_token'] as String,
          }),
        ),
      );
      final rotatedJson = await rotated.json() as Map<String, dynamic>;

      final reuse = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'refresh_token',
            'client_id': client.client.clientId,
            'refresh_token': first['refresh_token'] as String,
          }),
        ),
      );

      expect(reuse.statusCode, HttpStatus.badRequest);
      final reuseJson = await reuse.json() as Map<String, dynamic>;
      expect(reuseJson['error'], 'invalid_grant');

      final lookup = await tokenStore.lookupAccess(
        rotatedJson['access_token'] as String,
      );
      expect(lookup, isNull);
    });

    test('scope cannot widen', () async {
      final client = await registerPublic();
      final code = await codeStore.mint(
        clientId: client.client.clientId,
        redirectUri: 'https://agent.example/callback',
        codeChallenge: pkceS256Challenge(_verifier),
        scopes: {'notes:read'},
        resource: _resource,
        actor: 'desk-assistant',
        grantId: 'grant-narrow',
      );
      final exchange = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'authorization_code',
            'client_id': client.client.clientId,
            'code': code,
            'redirect_uri': 'https://agent.example/callback',
            'code_verifier': _verifier,
          }),
        ),
      );
      final exchangeJson = await exchange.json() as Map<String, dynamic>;

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'refresh_token',
            'client_id': client.client.clientId,
            'refresh_token': exchangeJson['refresh_token'] as String,
            'scope': 'notes:read notes:write',
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['error'], 'invalid_scope');
    });

    test("an empty scope on refresh keeps the grant's existing scope",
        () async {
      final client = await registerPublic();
      final first = await exchange(client);

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'refresh_token',
            'client_id': client.client.clientId,
            'refresh_token': first['refresh_token'] as String,
            'scope': '',
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['scope'], 'notes:read notes:write');
    });

    test('expired refresh token is rejected', () async {
      final client = await registerPublic();
      final first = await exchange(client);
      clock.advance(const Duration(days: 31));

      final res = await route.onRequest(
        _ctx(
          clientStore: clientStore,
          codeStore: codeStore,
          tokenStore: tokenStore,
          formBody: _formEncode({
            'grant_type': 'refresh_token',
            'client_id': client.client.clientId,
            'refresh_token': first['refresh_token'] as String,
          }),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final json = await res.json() as Map<String, dynamic>;
      expect(json['error'], 'invalid_grant');
    });
  });
}
