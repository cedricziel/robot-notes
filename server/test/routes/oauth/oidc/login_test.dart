import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oidc/discovery.dart';
import 'package:server/src/oidc/pending_login_store.dart';
import 'package:test/test.dart';

import '../../../../routes/oauth/oidc/login.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

const _publicUrl = 'http://localhost';
const _oidcClientId = 'robot-notes';

Config _config({bool oidcConfigured = true}) => Config(
      apiKey: 'rn_test',
      dataDir: '/tmp',
      port: 8080,
      lockTtlSeconds: 60,
      publicUrl: _publicUrl,
      oidc: oidcConfigured
          ? const OidcConfig(
              issuer: 'https://idp.example.com',
              clientId: _oidcClientId,
              clientSecret: 'shh',
            )
          : null,
    );

const _discovery = OidcDiscoveryDocument(
  authorizationEndpoint: 'https://idp.example.com/authorize',
  tokenEndpoint: 'https://idp.example.com/token',
  jwksUri: 'https://idp.example.com/jwks.json',
);

RequestContext _ctx({
  required Map<String, String> queryParameters,
  ClientStore? clientStore,
  PendingLoginStore? pendingLoginStore,
  Config? config,
  OidcDiscoveryDocument? discovery,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(HttpMethod.get);
  when(() => req.uri).thenReturn(
    Uri.parse('$_publicUrl/oauth/oidc/login')
        .replace(queryParameters: queryParameters),
  );
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Config>()).thenReturn(config ?? _config());
  when(() => ctx.read<ClientStore>()).thenReturn(clientStore!);
  when(() => ctx.read<PendingLoginStore>())
      .thenReturn(pendingLoginStore ?? PendingLoginStore());
  when(() => ctx.read<OidcDiscoveryDocument?>())
      .thenReturn(discovery ?? _discovery);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-oidc-login-route-test-');

void main() {
  late Directory tmp;
  late ClientStore clientStore;
  late RegisteredClient client;

  setUp(() async {
    tmp = _tempDir();
    final clock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
    clientStore =
        ClientStore(dir: Directory('${tmp.path}/clients'), clock: clock);
    client = await clientStore.register(
      clientName: 'Robot Notes App',
      redirectUris: ['http://127.0.0.1:53421/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, String> validQuery() => {
        'client_id': client.client.clientId,
        'redirect_uri': client.client.redirectUris.first,
        'response_type': 'code',
        'code_challenge': 'challenge-abc',
        'code_challenge_method': 'S256',
        'resource': _publicUrl,
        'state': 'original-client-state',
      };

  test('redirects to the provider with the expected authorize parameters',
      () async {
    final pendingLoginStore = PendingLoginStore();
    final res = await route.onRequest(
      _ctx(
        queryParameters: validQuery(),
        clientStore: clientStore,
        pendingLoginStore: pendingLoginStore,
      ),
    );

    expect(res.statusCode, HttpStatus.found);
    final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
    expect(location.origin, 'https://idp.example.com');
    expect(location.path, '/authorize');
    expect(location.queryParameters['response_type'], 'code');
    expect(location.queryParameters['client_id'], _oidcClientId);
    expect(
      location.queryParameters['redirect_uri'],
      '$_publicUrl/oauth/oidc/callback',
    );
    expect(location.queryParameters['scope'], contains('openid'));
    expect(location.queryParameters['code_challenge_method'], 'S256');
    expect(location.queryParameters['state'], isNotEmpty);
    expect(location.queryParameters['nonce'], isNotEmpty);
  });

  test('persists a pending login bound to the original consent request',
      () async {
    final pendingLoginStore = PendingLoginStore();
    final res = await route.onRequest(
      _ctx(
        queryParameters: validQuery(),
        clientStore: clientStore,
        pendingLoginStore: pendingLoginStore,
      ),
    );

    final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
    final state = location.queryParameters['state']!;
    final pending = pendingLoginStore.take(state);
    expect(pending, isNotNull);
    expect(pending!.consentRequest['client_id'], client.client.clientId);
    expect(
      pending.consentRequest['redirect_uri'],
      client.client.redirectUris.first,
    );
    expect(pending.consentRequest['state'], 'original-client-state');
    expect(
      pending.codeChallenge,
      isNot('challenge-abc'), // this login's own PKCE, not the client's
    );
  });

  test('an unknown client_id does not redirect to the provider', () async {
    final res = await route.onRequest(
      _ctx(
        queryParameters: validQuery()..['client_id'] = 'does-not-exist',
        clientStore: clientStore,
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('an unregistered redirect_uri does not redirect to the provider',
      () async {
    final res = await route.onRequest(
      _ctx(
        queryParameters: validQuery()
          ..['redirect_uri'] = 'https://not-registered.example/callback',
        clientStore: clientStore,
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('a request when OIDC is not configured is not found', () async {
    final res = await route.onRequest(
      _ctx(
        queryParameters: validQuery(),
        clientStore: clientStore,
        config: _config(oidcConfigured: false),
      ),
    );

    expect(res.statusCode, HttpStatus.notFound);
  });
}
