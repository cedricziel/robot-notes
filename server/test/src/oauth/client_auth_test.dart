import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/oauth/client_auth.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/oauth_records.dart';
import 'package:server/src/oauth/store_support.dart';
import 'package:test/test.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required ClientStore store,
  Map<String, String> headers = const {},
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<ClientStore>()).thenReturn(store);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-client-auth-test-');

void main() {
  late Directory tmp;
  late ClientStore store;

  setUp(() {
    tmp = _tempDir();
    store = ClientStore(dir: Directory('${tmp.path}/clients'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('resolves a public (none) client from the body client_id', () async {
    final registered = await store.register(
      clientName: 'Public',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );

    final result = await authenticateClient(
      _ctx(store: store),
      {'client_id': registered.client.clientId},
    );

    expect(result.isSuccess, isTrue);
    expect(result.client!.clientId, registered.client.clientId);
  });

  test('a none client presenting a secret is still accepted', () async {
    final registered = await store.register(
      clientName: 'Public',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'none',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );

    final result = await authenticateClient(
      _ctx(store: store),
      {
        'client_id': registered.client.clientId,
        'client_secret': 'whatever',
      },
    );

    expect(result.isSuccess, isTrue);
  });

  test('resolves client_secret_post with the correct secret', () async {
    final registered = await store.register(
      clientName: 'Confidential',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'client_secret_post',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );

    final result = await authenticateClient(
      _ctx(store: store),
      {
        'client_id': registered.client.clientId,
        'client_secret': registered.clientSecret!,
      },
    );

    expect(result.isSuccess, isTrue);
  });

  test('client_secret_post fails with a wrong secret', () async {
    final registered = await store.register(
      clientName: 'Confidential',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'client_secret_post',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );

    final result = await authenticateClient(
      _ctx(store: store),
      {
        'client_id': registered.client.clientId,
        'client_secret': 'wrong',
      },
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, 'invalid_client');
  });

  test('resolves client_secret_basic from the Authorization header', () async {
    final registered = await store.register(
      clientName: 'Basic',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'client_secret_basic',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
    final credentials = base64Encode(
      utf8.encode('${registered.client.clientId}:${registered.clientSecret}'),
    );

    final result = await authenticateClient(
      _ctx(
        store: store,
        headers: {'authorization': 'Basic $credentials'},
      ),
      const {},
    );

    expect(result.isSuccess, isTrue);
    expect(result.client!.clientId, registered.client.clientId);
  });

  test('resolves client_secret_basic with a lower-case "basic" scheme',
      () async {
    final registered = await store.register(
      clientName: 'Basic',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'client_secret_basic',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );
    final credentials = base64Encode(
      utf8.encode('${registered.client.clientId}:${registered.clientSecret}'),
    );

    final result = await authenticateClient(
      _ctx(
        store: store,
        headers: {'authorization': 'basic $credentials'},
      ),
      const {},
    );

    expect(result.isSuccess, isTrue);
  });

  test(
      'form-urldecodes the client_secret before comparing it '
      '(RFC 6749 §2.3.1)', () async {
    // client_id can't itself carry reserved characters (ClientStore only
    // ever mints base64url ids and rejects anything else as unsafe), but a
    // compliant client still form-encodes the secret before building the
    // Basic header, so the server must decode it back before comparing.
    const clientId = 'form-encoded-secret-client';
    const rawSecret = 'sec ret+with@chars';
    final client = OAuthClient(
      clientId: clientId,
      clientName: 'Form Encoded',
      redirectUris: const ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'client_secret_basic',
      grantTypes: const ['authorization_code'],
      responseTypes: const ['code'],
      clientSecretHash: hashSecret(rawSecret),
      createdAt: DateTime.utc(2026),
    );
    await atomicWriteJsonFile(
      File('${tmp.path}/clients/$clientId.json'),
      client.toJson(),
    );
    final encodedSecret = Uri.encodeQueryComponent(rawSecret);
    final credentials = base64Encode(utf8.encode('$clientId:$encodedSecret'));

    final result = await authenticateClient(
      _ctx(
        store: store,
        headers: {'authorization': 'Basic $credentials'},
      ),
      const {},
    );

    expect(result.isSuccess, isTrue);
  });

  test('client_secret_basic without the header fails', () async {
    final registered = await store.register(
      clientName: 'Basic',
      redirectUris: ['https://agent.example/callback'],
      tokenEndpointAuthMethod: 'client_secret_basic',
      grantTypes: ['authorization_code', 'refresh_token'],
      responseTypes: ['code'],
    );

    final result = await authenticateClient(
      _ctx(store: store),
      {'client_id': registered.client.clientId},
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, 'invalid_client');
    expect(result.wwwAuthenticate, 'Basic realm="robot-notes"');
  });

  test('unknown client_id fails', () async {
    final result = await authenticateClient(
      _ctx(store: store),
      {'client_id': 'does-not-exist'},
    );

    expect(result.isSuccess, isFalse);
    expect(result.error, 'invalid_client');
  });

  test('missing client_id fails', () async {
    final result = await authenticateClient(_ctx(store: store), const {});

    expect(result.isSuccess, isFalse);
    expect(result.error, 'invalid_client');
  });
}
