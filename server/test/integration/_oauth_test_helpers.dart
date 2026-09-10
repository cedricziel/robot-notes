import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:server/src/oauth/pkce.dart';

/// The tokens and client id resulting from one completed OAuth grant,
/// suitable for driving further `/oauth/token` (refresh) or
/// `/oauth/revoke` calls, or for authenticating at `/mcp`.
class OAuthGrant {
  /// Bundles the client id and issued token pair.
  const OAuthGrant({
    required this.clientId,
    required this.accessToken,
    required this.refreshToken,
  });

  /// The registered client this grant belongs to.
  final String clientId;

  /// Raw bearer credential accepted at `/mcp`.
  final String accessToken;

  /// Raw credential for the next `/oauth/token` refresh.
  final String refreshToken;
}

/// Generates a fresh PKCE verifier/challenge pair using
/// [pkceS256Challenge].
({String verifier, String challenge}) generatePkcePair() {
  final random = Random.secure();
  final verifierBytes = List<int>.generate(32, (_) => random.nextInt(256));
  final verifier = base64Url.encode(verifierBytes).replaceAll('=', '');
  return (verifier: verifier, challenge: pkceS256Challenge(verifier));
}

/// Drives the full OAuth 2.1 + PKCE flow over HTTP against a server at
/// [baseUrl] guarded by [apiKey]: register a public client, submit
/// consent with the workspace API key, and exchange the resulting code
/// for a token pair.
///
/// Takes the base URL and key directly (rather than a `TestApp`) so it
/// also works against a server instance stood up by hand — e.g. the
/// "survives a restart" scenario in `mcp_flow_test.dart`, which needs two
/// server lifecycles sharing one data directory and cannot use
/// `TestApp.start`'s tmp-dir-owning lifecycle for that. Mirrors the flow
/// asserted step by step in `oauth_flow_test.dart`.
///
/// [resource] defaults to `<baseUrl>/mcp`; pass it explicitly when the
/// server's configured public URL (and therefore the resource its tokens
/// are bound to) differs from the address used to reach it, as happens
/// when a fixed `Config.publicUrl` is set so the resource stays stable
/// across a restart onto a new ephemeral port.
Future<OAuthGrant> completeOAuthFlow({
  required String baseUrl,
  required String apiKey,
  String actor = 'desk-assistant',
  String? scope,
  String? resource,
  String redirectUri = 'https://agent.example/callback',
  String clientName = 'Integration Test Agent',
}) async {
  final pkce = generatePkcePair();
  final grantResource = resource ?? '$baseUrl/mcp';

  final registerRes = await http.post(
    Uri.parse('$baseUrl/oauth/register'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'client_name': clientName,
      'redirect_uris': [redirectUri],
    }),
  );
  final registration = jsonDecode(registerRes.body) as Map<String, dynamic>;
  final clientId = registration['client_id'] as String;

  final consentRequest = http.Request(
    'POST',
    Uri.parse('$baseUrl/oauth/authorize'),
  )
    ..followRedirects = false
    ..bodyFields = {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      'resource': grantResource,
      'api_key': apiKey,
      'actor': actor,
      if (scope != null) 'scope': scope,
    };
  final consentStreamed = await http.Client().send(consentRequest);
  final consentRes = await http.Response.fromStream(consentStreamed);
  final location = Uri.parse(consentRes.headers['location']!);
  final code = location.queryParameters['code']!;

  final tokenRes = await http.post(
    Uri.parse('$baseUrl/oauth/token'),
    body: {
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': pkce.verifier,
    },
  );
  final tokens = jsonDecode(tokenRes.body) as Map<String, dynamic>;
  return OAuthGrant(
    clientId: clientId,
    accessToken: tokens['access_token'] as String,
    refreshToken: tokens['refresh_token'] as String,
  );
}
