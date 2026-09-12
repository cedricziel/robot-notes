import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:logging/logging.dart';
import 'package:server/src/config.dart';
import 'package:server/src/oauth/authorize_request.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/error_page.dart';
import 'package:server/src/oidc/discovery.dart';
import 'package:server/src/oidc/id_token.dart';
import 'package:server/src/oidc/jwks.dart';
import 'package:server/src/oidc/pending_login_store.dart';
import 'package:server/src/oidc/token_exchange.dart';
import 'package:server/src/public_url.dart';

final Logger _log = Logger('oauth.oidc.callback');

/// `GET /oauth/oidc/callback` — the redirect target the configured OIDC
/// provider sends the user agent back to after login. Exchanges the
/// authorization `code` for an ID token, verifies it, and — on success —
/// completes the original `/oauth/authorize` consent request exactly as a
/// correct `api_key` submission would, using the verified identity as the
/// actor.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final oidcConfig = context.read<Config>().oidc;
  final discovery = context.read<OidcDiscoveryDocument?>();
  final jwks = context.read<JwksCache?>();
  if (oidcConfig == null || discovery == null || jwks == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }

  final Map<String, String> params;
  try {
    params = context.request.uri.queryParameters;
  } on FormatException {
    return oauthErrorPage('Malformed query string.');
  }

  final state = params['state'];
  final code = params['code'];
  if (state == null || code == null) {
    return oauthErrorPage('Missing code or state.');
  }

  final pending = context.read<PendingLoginStore>().take(state);
  if (pending == null) {
    return oauthErrorPage('Unknown or expired login attempt.');
  }

  final String idToken;
  try {
    idToken = await exchangeCodeForIdToken(
      tokenEndpoint: discovery.tokenEndpoint,
      code: code,
      redirectUri: '${publicBaseUrl(context)}/oauth/oidc/callback',
      codeVerifier: pending.codeVerifier,
      clientId: oidcConfig.clientId,
      clientSecret: oidcConfig.clientSecret,
      httpPost: context.read<HttpPostForm>(),
    );
  } on OidcTokenExchangeException catch (e) {
    _log.warning(e.message);
    return oauthErrorPage('Could not exchange the authorization code.');
  }

  final IdTokenClaims claims;
  try {
    claims = await verifyIdToken(
      idToken,
      issuer: oidcConfig.issuer,
      audience: oidcConfig.clientId,
      nonce: pending.nonce,
      jwks: jwks,
    );
  } on IdTokenVerificationException catch (e) {
    _log.warning('${e.failure}: ${e.message}');
    return oauthErrorPage("Could not verify the identity provider's response.");
  }

  final actor = claims.name ?? claims.email ?? claims.sub;

  final consentRequest = pending.consentRequest;
  final client =
      await context.read<ClientStore>().get(consentRequest['client_id']!);
  if (client == null) {
    return oauthErrorPage('The original client is no longer registered.');
  }

  final valid = AuthorizeValid(
    client: client,
    redirectUri: consentRequest['redirect_uri']!,
    codeChallenge: consentRequest['code_challenge']!,
    scopes: consentRequest['scope']!.split(' ').toSet(),
    resource: consentRequest['resource']!,
    state: consentRequest['state'],
  );

  final location = await mintAuthorizationCodeRedirect(
    context,
    valid: valid,
    actor: actor,
  );
  return Response(
    statusCode: HttpStatus.found,
    headers: {HttpHeaders.locationHeader: location},
  );
}
