import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:server/src/oauth/pkce.dart';
import 'package:test/test.dart';

import '_test_app.dart';

/// End-to-end OAuth flow, driven entirely over HTTP against [TestApp]:
///   1. `POST /oauth/register` mints a public client (no static key).
///   2. `GET /oauth/authorize` renders the consent page.
///   3. `POST /oauth/authorize` proves ownership with the API key and
///      redirects with a code (the redirect is inspected, not followed).
///   4. `POST /oauth/token` exchanges the code with a real PKCE pair.
///   5. `POST /oauth/token` refreshes the access token.
///   6. `POST /oauth/revoke` revokes the new refresh token, cascading to
///      its access token.
///
/// Also covers the `auth` capability's delta scenarios: registering does
/// not require the static key, and completing a grant never changes what
/// the static key can do.
void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.start();
  });

  tearDown(() async {
    await app.close();
  });

  test(
    'register -> authorize -> consent -> token -> refresh -> revoke',
    () async {
      final random = Random.secure();
      final verifierBytes = List<int>.generate(32, (_) => random.nextInt(256));
      final verifier = base64Url.encode(verifierBytes).replaceAll('=', '');
      final challenge = pkceS256Challenge(verifier);

      // 1. Register a public client with no Authorization header at all —
      // the `auth` delta scenario "OAuth registration bypasses the static
      // key".
      final registerRes = await http.post(
        Uri.parse('${app.baseUrl}/oauth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Integration Test Agent',
          'redirect_uris': ['https://agent.example/callback'],
        }),
      );
      expect(registerRes.statusCode, 201, reason: registerRes.body);
      final registration = jsonDecode(registerRes.body) as Map<String, dynamic>;
      final clientId = registration['client_id'] as String;
      expect(registration.containsKey('client_secret'), isFalse);

      // 2. GET the authorize endpoint: renders the consent page.
      final authorizeUri = Uri.parse('${app.baseUrl}/oauth/authorize').replace(
        queryParameters: {
          'client_id': clientId,
          'redirect_uri': 'https://agent.example/callback',
          'response_type': 'code',
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': 'xyz-state',
          'resource': '${app.baseUrl}/mcp',
        },
      );
      final consentGetRes = await http.get(authorizeUri);
      expect(consentGetRes.statusCode, 200, reason: consentGetRes.body);
      expect(consentGetRes.headers['content-type'], contains('text/html'));
      expect(consentGetRes.body, contains('Integration Test Agent'));

      // 3. POST the consent form; follow the redirect manually.
      final consentRequest = http.Request(
        'POST',
        Uri.parse('${app.baseUrl}/oauth/authorize'),
      )
        ..followRedirects = false
        ..bodyFields = {
          'client_id': clientId,
          'redirect_uri': 'https://agent.example/callback',
          'response_type': 'code',
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': 'xyz-state',
          'resource': '${app.baseUrl}/mcp',
          'api_key': app.config.apiKey,
          'actor': 'desk-assistant',
        };
      final consentStreamed = await http.Client().send(consentRequest);
      final consentRes = await http.Response.fromStream(consentStreamed);
      expect(consentRes.statusCode, 302, reason: consentRes.body);
      final location = Uri.parse(consentRes.headers['location']!);
      expect(location.toString(), startsWith('https://agent.example/callback'));
      expect(location.queryParameters['state'], 'xyz-state');
      expect(location.queryParameters['iss'], app.baseUrl);
      final code = location.queryParameters['code']!;

      // 4. Exchange the code for tokens.
      final tokenRes = await http.post(
        Uri.parse('${app.baseUrl}/oauth/token'),
        body: {
          'grant_type': 'authorization_code',
          'client_id': clientId,
          'code': code,
          'redirect_uri': 'https://agent.example/callback',
          'code_verifier': verifier,
        },
      );
      expect(tokenRes.statusCode, 200, reason: tokenRes.body);
      expect(tokenRes.headers['cache-control'], 'no-store');
      final tokens = jsonDecode(tokenRes.body) as Map<String, dynamic>;
      final accessToken = tokens['access_token'] as String;
      final refreshToken = tokens['refresh_token'] as String;
      expect(tokens['token_type'], 'Bearer');
      expect(tokens['scope'], 'notes:read notes:write');

      // The `auth` delta scenario "OAuth endpoints do not alter the key":
      // the original static key still works against the REST API, and
      // the freshly minted OAuth access token does not.
      final restWithKeyRes = await http.get(
        Uri.parse('${app.baseUrl}/notes'),
        headers: app.headers(),
      );
      expect(restWithKeyRes.statusCode, 200, reason: restWithKeyRes.body);
      final restWithTokenRes = await http.get(
        Uri.parse('${app.baseUrl}/notes'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      expect(restWithTokenRes.statusCode, 401);

      // 5. Refresh: rotates to a new access/refresh pair.
      final refreshRes = await http.post(
        Uri.parse('${app.baseUrl}/oauth/token'),
        body: {
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'refresh_token': refreshToken,
        },
      );
      expect(refreshRes.statusCode, 200, reason: refreshRes.body);
      final refreshed = jsonDecode(refreshRes.body) as Map<String, dynamic>;
      final rotatedAccessToken = refreshed['access_token'] as String;
      final rotatedRefreshToken = refreshed['refresh_token'] as String;
      expect(rotatedAccessToken, isNot(accessToken));
      expect(rotatedRefreshToken, isNot(refreshToken));

      // The original access token remains usable until it expires; it is
      // a separate credential from the refresh token that was rotated.
      final lookupOriginal =
          await app.deps.tokenStore.lookupAccess(accessToken);
      expect(lookupOriginal, isNotNull);

      // 6. Revoke the rotated refresh token: cascades to its access token.
      final revokeRes = await http.post(
        Uri.parse('${app.baseUrl}/oauth/revoke'),
        body: {'client_id': clientId, 'token': rotatedRefreshToken},
      );
      expect(revokeRes.statusCode, 200, reason: revokeRes.body);

      final lookupRotated =
          await app.deps.tokenStore.lookupAccess(rotatedAccessToken);
      expect(lookupRotated, isNull);
    },
  );
}
