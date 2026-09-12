import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/config.dart';
import 'package:server/src/oauth/authorize_request.dart';
import 'package:server/src/oauth/error_page.dart';
import 'package:server/src/oidc/discovery.dart';
import 'package:server/src/oidc/pending_login_store.dart';
import 'package:server/src/public_url.dart';

/// `GET /oauth/oidc/login` — starts an OIDC login for the `/oauth/authorize`
/// consent request whose (already-once-validated) parameters are forwarded
/// here as this request's own query string by the consent page's sign-in
/// link. Re-validates them (defense in depth, mirroring how `POST
/// /oauth/authorize` re-validates its forwarded hidden fields), then
/// redirects to the configured OIDC provider.
///
/// 404s when OIDC login is not configured.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final oidcConfig = context.read<Config>().oidc;
  if (oidcConfig == null) {
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

  final validation = await validateAuthorizeRequest(context, params);
  return switch (validation) {
    AuthorizeClientError(:final message) => oauthErrorPage(message),
    AuthorizeRedirectError(:final redirectUri, :final error, :final state) =>
      _redirectWithError(redirectUri, error: error, state: state),
    final AuthorizeValid valid => _startLogin(context, valid, oidcConfig),
  };
}

Response _startLogin(
  RequestContext context,
  AuthorizeValid valid,
  OidcConfig oidcConfig,
) {
  final discovery = context.read<OidcDiscoveryDocument?>();
  if (discovery == null) {
    // Config.oidc != null guarantees AppDeps.bootstrap already resolved
    // this; reaching here would mean bootstrap didn't run, which is a
    // deployment bug, not a client-triggerable condition.
    return oauthErrorPage(
      'OIDC login is misconfigured.',
      statusCode: HttpStatus.internalServerError,
    );
  }

  final base = publicBaseUrl(context);
  final pendingLoginStore = context.read<PendingLoginStore>();
  final pending = pendingLoginStore.start(
    consentRequest: {
      'client_id': valid.client.clientId,
      'redirect_uri': valid.redirectUri,
      'code_challenge': valid.codeChallenge,
      'scope': (valid.scopes.toList()..sort()).join(' '),
      'resource': valid.resource,
      if (valid.state != null) 'state': valid.state!,
    },
  );

  final redirectUri = Uri.parse(discovery.authorizationEndpoint).replace(
    queryParameters: {
      'response_type': 'code',
      'client_id': oidcConfig.clientId,
      'redirect_uri': '$base/oauth/oidc/callback',
      'scope': 'openid profile email',
      'code_challenge': pending.codeChallenge,
      'code_challenge_method': 'S256',
      'state': pending.state,
      'nonce': pending.nonce,
    },
  );

  return Response(
    statusCode: HttpStatus.found,
    headers: {HttpHeaders.locationHeader: redirectUri.toString()},
  );
}

Response _redirectWithError(
  String redirectUri, {
  required String error,
  String? state,
}) {
  final location = appendQuery(redirectUri, {
    'error': error,
    if (state != null) 'state': state,
  });
  return Response(
    statusCode: HttpStatus.found,
    headers: {HttpHeaders.locationHeader: location.toString()},
  );
}
