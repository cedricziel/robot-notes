import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oidc/discovery.dart';
import 'package:server/src/oidc/jwks.dart';
import 'package:server/src/oidc/pending_login_store.dart';
import 'package:server/src/oidc/token_exchange.dart';
import 'package:test/test.dart';

import '../../../../routes/oauth/oidc/callback.dart' as route;
import '../../../src/oidc/_id_token_test_helpers.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

const _publicUrl = 'http://localhost';
const _issuer = 'https://idp.example.com';
const _oidcClientId = 'robot-notes';
const _oidcClientSecret = 'shh';

Config _config() => const Config(
      apiKey: 'rn_test',
      dataDir: '/tmp',
      port: 8080,
      lockTtlSeconds: 60,
      publicUrl: _publicUrl,
      oidc: OidcConfig(
        issuer: _issuer,
        clientId: _oidcClientId,
        clientSecret: _oidcClientSecret,
      ),
    );

RequestContext _ctx({
  required Map<String, String> queryParameters,
  required ClientStore clientStore,
  required CodeStore codeStore,
  required PendingLoginStore pendingLoginStore,
  required JwksCache jwksCache,
  required HttpPostForm httpPostForm,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(HttpMethod.get);
  when(() => req.uri).thenReturn(
    Uri.parse('$_publicUrl/oauth/oidc/callback')
        .replace(queryParameters: queryParameters),
  );
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Config>()).thenReturn(_config());
  when(() => ctx.read<ClientStore>()).thenReturn(clientStore);
  when(() => ctx.read<CodeStore>()).thenReturn(codeStore);
  when(() => ctx.read<PendingLoginStore>()).thenReturn(pendingLoginStore);
  when(() => ctx.read<OidcDiscoveryDocument?>()).thenReturn(
    const OidcDiscoveryDocument(
      authorizationEndpoint: '$_issuer/authorize',
      tokenEndpoint: '$_issuer/token',
      jwksUri: '$_issuer/jwks.json',
    ),
  );
  when(() => ctx.read<JwksCache?>()).thenReturn(jwksCache);
  when(() => ctx.read<HttpPostForm>()).thenReturn(httpPostForm);
  return ctx;
}

Directory _tempDir() => Directory.systemTemp
    .createTempSync('robot-notes-oidc-callback-route-test-');

/// Captures every record `routes/oauth/oidc/callback.dart` logs under its
/// `oauth.oidc.callback` scope for the running test's duration, cancelling
/// the listener via [addTearDown] so it doesn't leak across tests.
List<LogRecord> _captureLogs() {
  hierarchicalLoggingEnabled = true;
  Logger('oauth.oidc.callback').level = Level.ALL;
  final records = <LogRecord>[];
  final sub = Logger('oauth.oidc.callback').onRecord.listen(records.add);
  addTearDown(sub.cancel);
  return records;
}

void main() {
  late Directory tmp;
  late ClientStore clientStore;
  late CodeStore codeStore;
  late RegisteredClient client;
  late PendingLoginStore pendingLoginStore;
  late JwksCache jwksCache;
  late TestRsaKeyPair rsa;

  setUp(() async {
    tmp = _tempDir();
    final clock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
    clientStore =
        ClientStore(dir: Directory('${tmp.path}/clients'), clock: clock);
    codeStore = CodeStore(dir: Directory('${tmp.path}/codes'), clock: clock);
    client = await clientStore.register(
      clientName: 'Robot Notes App',
      redirectUris: ['http://127.0.0.1:53421/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
    pendingLoginStore = PendingLoginStore(clock: clock);
    rsa = generateTestRsaKeyPair();
    jwksCache = JwksCache(
      jwksUri: '$_issuer/jwks.json',
      httpGet: (uri) async => jsonEncode({
        'keys': [rsa.jwk],
      }),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  PendingLogin startPendingLogin({String? clientState = 'original-state'}) =>
      pendingLoginStore.start(
        consentRequest: {
          'client_id': client.client.clientId,
          'redirect_uri': client.client.redirectUris.first,
          'code_challenge': 'client-code-challenge',
          'scope': 'notes:read notes:write',
          'resource': _publicUrl,
          if (clientState != null) 'state': clientState,
        },
      );

  Map<String, dynamic> idTokenPayload(
    PendingLogin pending, {
    String? name,
    String? email,
    String? sub,
    String? nonce,
    String? aud,
    String? iss,
    int? exp,
  }) {
    final now = DateTime.now().toUtc();
    return {
      'iss': iss ?? _issuer,
      'aud': aud ?? _oidcClientId,
      'sub': sub ?? 'user-123',
      'exp': exp ??
          now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
      'iat': now.millisecondsSinceEpoch ~/ 1000,
      'nonce': nonce ?? pending.nonce,
      if (name != null) 'name': name,
      if (email != null) 'email': email,
    };
  }

  HttpPostForm tokenEndpointReturning(String idToken) =>
      (uri, form) async => jsonEncode({'id_token': idToken});

  test('a successful callback mints a code and redirects to the client',
      () async {
    final pending = startPendingLogin();
    final idToken = signRs256(
      idTokenPayload(pending, name: 'Alice Example'),
      rsa,
    );

    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning(idToken),
      ),
    );

    expect(res.statusCode, HttpStatus.found);
    final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
    expect(location.origin, 'http://127.0.0.1:53421');
    expect(location.path, '/callback');
    expect(location.queryParameters['state'], 'original-state');
    expect(location.queryParameters['iss'], _publicUrl);
    final code = location.queryParameters['code']!;

    final record = await codeStore.consume(code, (c) async => c);
    expect(record.actor, 'Alice Example');
    expect(record.clientId, client.client.clientId);
    expect(record.codeChallenge, 'client-code-challenge');
    expect(record.resource, _publicUrl);
  });

  test('falls back to email, then sub, when name is absent', () async {
    final pending = startPendingLogin();
    final idToken = signRs256(
      idTokenPayload(pending, email: 'alice@example.com'),
      rsa,
    );

    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning(idToken),
      ),
    );

    final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
    final code = location.queryParameters['code']!;
    final record = await codeStore.consume(code, (c) async => c);
    expect(record.actor, 'alice@example.com');
  });

  test('falls back to sub when both name and email are absent', () async {
    final pending = startPendingLogin();
    final idToken = signRs256(
      idTokenPayload(pending, sub: 'user-only-sub'),
      rsa,
    );

    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning(idToken),
      ),
    );

    final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
    final code = location.queryParameters['code']!;
    final record = await codeStore.consume(code, (c) async => c);
    expect(record.actor, 'user-only-sub');
  });

  test('a state matching no pending login is rejected without minting',
      () async {
    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': 'unknown-state'},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning('should-not-be-used'),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('an ID token with a bad signature is rejected without minting',
      () async {
    final pending = startPendingLogin();
    final otherRsa = generateTestRsaKeyPair(kid: rsa.kid);
    final idToken = signRs256(idTokenPayload(pending), otherRsa);

    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning(idToken),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('an ID token with a bad signature logs a warning', () async {
    final records = _captureLogs();
    final pending = startPendingLogin();
    final otherRsa = generateTestRsaKeyPair(kid: rsa.kid);
    final idToken = signRs256(idTokenPayload(pending), otherRsa);

    await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning(idToken),
      ),
    );

    expect(records, isNotEmpty);
    expect(records.single.level, Level.WARNING);
  });

  test('a failed token exchange is rejected and logs a warning', () async {
    final records = _captureLogs();
    final pending = startPendingLogin();

    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: (uri, form) async =>
            throw const HttpException('connection refused'),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
    expect(records, isNotEmpty);
    expect(records.single.level, Level.WARNING);
    expect(records.single.message, contains('connection refused'));
  });

  test('a wrong-issuer ID token is rejected without minting', () async {
    final pending = startPendingLogin();
    final idToken = signRs256(
      idTokenPayload(pending, iss: 'https://not-the-idp.example.com'),
      rsa,
    );

    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning(idToken),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('a nonce-mismatched ID token is rejected without minting', () async {
    final pending = startPendingLogin();
    final idToken = signRs256(
      idTokenPayload(pending, nonce: 'wrong-nonce'),
      rsa,
    );

    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning(idToken),
      ),
    );

    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('using the same state twice fails the second time (single-use)',
      () async {
    final pending = startPendingLogin();
    final idToken = signRs256(idTokenPayload(pending), rsa);
    final httpPostForm = tokenEndpointReturning(idToken);

    final first = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: httpPostForm,
      ),
    );
    expect(first.statusCode, HttpStatus.found);

    final second = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: httpPostForm,
      ),
    );
    expect(second.statusCode, HttpStatus.badRequest);
  });

  test(
      'a pending login with no original state omits state on the final '
      'redirect', () async {
    final pending = startPendingLogin(clientState: null);
    final idToken = signRs256(idTokenPayload(pending), rsa);

    final res = await route.onRequest(
      _ctx(
        queryParameters: {'code': 'provider-code', 'state': pending.state},
        clientStore: clientStore,
        codeStore: codeStore,
        pendingLoginStore: pendingLoginStore,
        jwksCache: jwksCache,
        httpPostForm: tokenEndpointReturning(idToken),
      ),
    );

    final location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
    expect(location.queryParameters.containsKey('state'), isFalse);
  });
}
