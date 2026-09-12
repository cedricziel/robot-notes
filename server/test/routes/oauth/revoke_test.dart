import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:test/test.dart';

import '../../../routes/oauth/revoke.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required ClientStore clientStore,
  required TokenStore tokenStore,
  String? formBody,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(HttpMethod.post);
  when(() => req.headers).thenReturn(const {
    'content-type': 'application/x-www-form-urlencoded',
  });
  when(req.body).thenAnswer((_) async => formBody ?? '');
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<ClientStore>()).thenReturn(clientStore);
  when(() => ctx.read<TokenStore>()).thenReturn(tokenStore);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-revoke-route-test-');

String _formEncode(Map<String, String> fields) => fields.entries
    .map(
      (e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}',
    )
    .join('&');

void main() {
  late Directory tmp;
  late ClientStore clientStore;
  late TokenStore tokenStore;
  late Clock clock;

  setUp(() {
    tmp = _tempDir();
    clock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
    clientStore =
        ClientStore(dir: Directory('${tmp.path}/clients'), clock: clock);
    tokenStore = TokenStore(dir: Directory('${tmp.path}/tokens'), clock: clock);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('revoking a refresh token cascades to the access token', () async {
    final client = await clientStore.register(
      clientName: 'Public',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
    final issued = await tokenStore.issue(
      clientId: client.client.clientId,
      actor: 'desk-assistant',
      scopes: {'notes:read', 'notes:write'},
      resource: 'http://localhost/mcp',
      grantId: 'grant-1',
    );

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'client_id': client.client.clientId,
          'token': issued.refreshToken!,
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.ok);
    final lookup = await tokenStore.lookupAccess(issued.accessToken);
    expect(lookup, isNull);
  });

  test('revoking an access token is local (refresh token survives)', () async {
    final client = await clientStore.register(
      clientName: 'Public',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
    final issued = await tokenStore.issue(
      clientId: client.client.clientId,
      actor: 'desk-assistant',
      scopes: {'notes:read', 'notes:write'},
      resource: 'http://localhost/mcp',
      grantId: 'grant-1',
    );

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'client_id': client.client.clientId,
          'token': issued.accessToken,
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.ok);
    final accessLookup = await tokenStore.lookupAccess(issued.accessToken);
    expect(accessLookup, isNull);
    final refreshLookup = await tokenStore.lookupRefresh(issued.refreshToken);
    expect(refreshLookup, isNotNull);
  });

  test('revoking an unknown token is still 200', () async {
    final client = await clientStore.register(
      clientName: 'Public',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'client_id': client.client.clientId,
          'token': 'never-issued',
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.ok);
  });

  test("a client cannot revoke another client's token (RFC 7009 §2.1)",
      () async {
    final clientA = await clientStore.register(
      clientName: 'Client A',
      redirectUris: ['https://a.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
    final clientB = await clientStore.register(
      clientName: 'Client B',
      redirectUris: ['https://b.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
    final issuedForB = await tokenStore.issue(
      clientId: clientB.client.clientId,
      actor: 'desk-assistant',
      scopes: {'notes:read', 'notes:write'},
      resource: 'http://localhost/mcp',
      grantId: 'grant-b',
    );

    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'client_id': clientA.client.clientId,
          'token': issuedForB.refreshToken!,
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.ok);
    final accessLookup = await tokenStore.lookupAccess(
      issuedForB.accessToken,
    );
    expect(accessLookup, isNotNull);
    final refreshLookup = await tokenStore.lookupRefresh(
      issuedForB.refreshToken,
    );
    expect(refreshLookup, isNotNull);
  });

  test('a malformed percent-escape in the form body is invalid_request',
      () async {
    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        tokenStore: tokenStore,
        formBody: 'client_id=does-not-exist&token=%FF',
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_request');
  });

  test('a bad client is 401', () async {
    final res = await route.onRequest(
      _ctx(
        clientStore: clientStore,
        tokenStore: tokenStore,
        formBody: _formEncode({
          'client_id': 'does-not-exist',
          'token': 'whatever',
        }),
      ),
    );

    expect(res.statusCode, HttpStatus.unauthorized);
    final json = await res.json() as Map<String, dynamic>;
    expect(json['error'], 'invalid_client');
  });
}
