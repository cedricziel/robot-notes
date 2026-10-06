import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:server/src/config.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/pkce.dart';
import 'package:test/test.dart';

import '../src/oidc/_id_token_test_helpers.dart';
import '_test_app.dart';

/// End-to-end OIDC login, driven over real HTTP against [TestApp] and a
/// tiny stub OIDC provider (also real HTTP, on another loopback port):
///
///   1. Register an app client (as any MCP client would) and start
///      `GET /oauth/authorize` — OIDC is configured, so the consent page
///      carries a sign-in link instead of the `api_key` form.
///   2. Follow the sign-in link (`GET /oauth/oidc/login`), without
///      following its redirect, and capture the `state`/`nonce` our
///      server generated for the round trip to the stub provider.
///   3. Sign a real RS256 ID token — as the stub provider "would" —
///      bound to that captured `nonce`, and arm the stub's `/token`
///      endpoint to return it.
///   4. Simulate the provider's redirect back by hitting
///      `GET /oauth/oidc/callback` with the captured `state`: our server
///      exchanges the code at the stub, verifies the ID token, and
///      redirects to the app client with an authorization code.
///   5. Exchange that code at `POST /oauth/token` for an access token.
///   6. Call `GET /notes` with the token and confirm it works, with the
///      actor derived from the ID token's `name` claim.
void main() {
  late TestApp app;
  late HttpServer stub;
  late String stubIssuer;
  late TestRsaKeyPair rsa;
  String? tokenEndpointResponse;

  setUp(() async {
    rsa = generateTestRsaKeyPair();
    tokenEndpointResponse = null;

    stub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    stubIssuer = 'http://127.0.0.1:${stub.port}';
    unawaited(
      _serveStub(stub, () => stubIssuer, rsa, () => tokenEndpointResponse),
    );

    app = await TestApp.start(
      oidcConfig: OidcConfig(
        issuer: stubIssuer,
        clientId: 'robot-notes-app',
        clientSecret: 'app-secret',
      ),
    );
  });

  tearDown(() async {
    await app.close();
    await stub.close(force: true);
  });

  test('OIDC login with a changed loopback port mints a working access token',
      () async {
    // 1. Register a client and start /oauth/authorize.
    final registerRes = await http.post(
      Uri.parse('${app.baseUrl}/oauth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'client_name': 'Robot Notes App',
        'redirect_uris': ['http://127.0.0.1:53421/callback'],
      }),
    );
    expect(registerRes.statusCode, 201, reason: registerRes.body);
    final registration = jsonDecode(registerRes.body) as Map<String, dynamic>;
    final clientId = registration['client_id'] as String;

    final verifier = generateRandomToken(Random.secure(), 32);
    final challenge = pkceS256Challenge(verifier);

    final authorizeUri = Uri.parse('${app.baseUrl}/oauth/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': 'http://127.0.0.1:53601/callback',
        'response_type': 'code',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': 'app-original-state',
        'scope': 'notes:read notes:write vaults:manage',
        // REST/WS resource, not the default /mcp — so the resulting
        // access token can be used against /notes below.
        'resource': app.baseUrl,
      },
    );
    final consentRes = await http.get(authorizeUri);
    expect(consentRes.statusCode, 200);
    expect(consentRes.body, isNot(contains('name="api_key"')));

    // 2. Follow the sign-in link without following its redirect.
    final signInUri = Uri.parse('${app.baseUrl}/oauth/oidc/login').replace(
      queryParameters: {
        ...authorizeUri.queryParameters,
        'vault_default': 'yes'
      },
    );
    final loginReq = http.Request('GET', signInUri)..followRedirects = false;
    final loginStreamed = await loginReq.send();
    expect(loginStreamed.statusCode, 302);
    final providerRedirect = Uri.parse(loginStreamed.headers['location']!);
    expect(providerRedirect.origin, stubIssuer);
    final capturedState = providerRedirect.queryParameters['state']!;
    final capturedNonce = providerRedirect.queryParameters['nonce']!;

    // 3. Sign an ID token bound to the captured nonce, and arm the stub.
    final idToken = signRs256(
      {
        'iss': stubIssuer,
        'aud': 'robot-notes-app',
        'sub': 'user-1',
        'name': 'Alice Example',
        'nonce': capturedNonce,
        'exp': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch ~/
            1000,
        'iat': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      },
      rsa,
    );
    tokenEndpointResponse = jsonEncode({'id_token': idToken});

    // 4. Simulate the provider's redirect back to our callback.
    final callbackUri = Uri.parse('${app.baseUrl}/oauth/oidc/callback').replace(
      queryParameters: {'code': 'stub-code', 'state': capturedState},
    );
    final callbackReq = http.Request('GET', callbackUri)
      ..followRedirects = false;
    final callbackStreamed = await callbackReq.send();
    expect(callbackStreamed.statusCode, 302);
    final finalRedirect = Uri.parse(callbackStreamed.headers['location']!);
    expect(finalRedirect.origin, 'http://127.0.0.1:53601');
    expect(finalRedirect.queryParameters['state'], 'app-original-state');
    final code = finalRedirect.queryParameters['code']!;

    // 5. Exchange the code for an access token, using the app client's
    // own PKCE verifier (unrelated to the OIDC provider round trip).
    final tokenRes = await http.post(
      Uri.parse('${app.baseUrl}/oauth/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': 'http://127.0.0.1:53601/callback',
        'code_verifier': verifier,
        'client_id': clientId,
      },
    );
    expect(tokenRes.statusCode, 200, reason: tokenRes.body);
    final tokenBody = jsonDecode(tokenRes.body) as Map<String, dynamic>;
    final accessToken = tokenBody['access_token'] as String;

    // 6. The access token works against /notes, attributed to the
    // identity's name claim.
    final createRes = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'title': 'from-oidc-session'}),
    );
    expect(createRes.statusCode, 201, reason: createRes.body);

    final listRes = await http.get(
      Uri.parse('${app.baseUrl}/notes'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    expect(listRes.statusCode, 200, reason: listRes.body);

    final headers = {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json'
    };
    final vaultRes = await http.post(Uri.parse('${app.baseUrl}/vaults'),
        headers: headers, body: jsonEncode({'name': 'OIDC work'}));
    expect(vaultRes.statusCode, 201, reason: vaultRes.body);
    final vaultId =
        (jsonDecode(vaultRes.body) as Map<String, dynamic>)['id'] as String;
    final renameRes = await http.patch(
        Uri.parse('${app.baseUrl}/vaults/$vaultId'),
        headers: headers,
        body: jsonEncode({'name': 'Projects'}));
    expect(renameRes.statusCode, 200, reason: renameRes.body);
    final vaultNote = await http.post(Uri.parse('${app.baseUrl}/notes'),
        headers: {...headers, 'X-Vault-Id': vaultId},
        body: jsonEncode({'title': 'New vault note'}));
    expect(vaultNote.statusCode, 201, reason: vaultNote.body);
    final catalog =
        await http.get(Uri.parse('${app.baseUrl}/vaults'), headers: headers);
    final vaultCatalog = jsonDecode(catalog.body) as Map<String, dynamic>;
    expect(vaultCatalog['can_manage'], isTrue);
    expect(catalog.body, contains('Projects'));
    final refreshed =
        await http.post(Uri.parse('${app.baseUrl}/oauth/token'), body: {
      'grant_type': 'refresh_token',
      'client_id': clientId,
      'refresh_token': tokenBody['refresh_token'] as String,
    });
    expect(refreshed.statusCode, 200, reason: refreshed.body);
    final nextToken = (jsonDecode(refreshed.body)
        as Map<String, dynamic>)['access_token'] as String;
    final afterRefresh = await http.get(Uri.parse('${app.baseUrl}/notes'),
        headers: {'Authorization': 'Bearer $nextToken', 'X-Vault-Id': vaultId});
    expect(afterRefresh.statusCode, 200, reason: afterRefresh.body);
    expect(afterRefresh.body, contains('New vault note'));
  });
}

Future<void> _serveStub(
  HttpServer server,
  String Function() issuer,
  TestRsaKeyPair rsa,
  String? Function() tokenResponse,
) async {
  await for (final request in server) {
    final path = request.uri.path;
    if (path == '/.well-known/openid-configuration') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'issuer': issuer(),
          'authorization_endpoint': '${issuer()}/authorize',
          'token_endpoint': '${issuer()}/token',
          'jwks_uri': '${issuer()}/jwks.json',
        }),
      );
    } else if (path == '/jwks.json') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'keys': [rsa.jwk],
        }),
      );
    } else if (path == '/token') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(tokenResponse() ?? jsonEncode({}));
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }
}
