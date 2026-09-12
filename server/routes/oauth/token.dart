import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/oauth/client_auth.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/form_body.dart';
import 'package:server/src/oauth/oauth_records.dart';
import 'package:server/src/oauth/oauth_response.dart';
import 'package:server/src/oauth/pkce.dart';
import 'package:server/src/oauth/token_store.dart';

/// `POST /oauth/token` — exchanges an authorization code, or a refresh
/// token, for a new access/refresh token pair.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final Map<String, String> form;
  try {
    form = await parseFormBody(context.request);
  } on UnsupportedFormContentTypeException {
    return oauthError(HttpStatus.badRequest, 'invalid_request');
  }

  final grantType = form['grant_type'];
  if (grantType != 'authorization_code' && grantType != 'refresh_token') {
    return oauthError(HttpStatus.badRequest, 'unsupported_grant_type');
  }

  final authResult = await authenticateClient(context, form);
  if (!authResult.isSuccess) {
    return oauthError(
      HttpStatus.unauthorized,
      authResult.error!,
      extraHeaders: authResult.wwwAuthenticate == null
          ? null
          : {'WWW-Authenticate': authResult.wwwAuthenticate!},
    );
  }
  final client = authResult.client!;

  return grantType == 'authorization_code'
      ? _exchangeCode(context, client: client, form: form)
      : _refresh(context, client: client, form: form);
}

Future<Response> _exchangeCode(
  RequestContext context, {
  required OAuthClient client,
  required Map<String, String> form,
}) async {
  final code = form['code'];
  final redirectUri = form['redirect_uri'];
  final verifier = form['code_verifier'];
  if (code == null || redirectUri == null || verifier == null) {
    return oauthError(HttpStatus.badRequest, 'invalid_request');
  }

  final AuthorizationCode record;
  try {
    record = await context.read<CodeStore>().consume(code);
  } on CodeReusedException catch (e) {
    await context.read<TokenStore>().revokeGrant(e.grantId);
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  } on CodeNotFoundException {
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  }

  final requestedResource = form['resource'];
  final mismatched = record.clientId != client.clientId ||
      record.redirectUri != redirectUri ||
      !pkceVerify(challenge: record.codeChallenge, verifier: verifier) ||
      (requestedResource != null && requestedResource != record.resource);
  if (mismatched) {
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  }

  final issued = await context.read<TokenStore>().issue(
        clientId: client.clientId,
        actor: record.actor,
        scopes: record.scopes,
        resource: record.resource,
        grantId: record.grantId,
      );
  return _tokenResponse(issued);
}

Future<Response> _refresh(
  RequestContext context, {
  required OAuthClient client,
  required Map<String, String> form,
}) async {
  final refreshToken = form['refresh_token'];
  if (refreshToken == null) {
    return oauthError(HttpStatus.badRequest, 'invalid_request');
  }

  final tokenStore = context.read<TokenStore>();

  // A live (unrotated, unrevoked, unexpired) token belonging to a
  // different client is refused outright, so possessing another client's
  // raw refresh token isn't enough to mint fresh credentials under it.
  // A dead token (already rotated/revoked/expired) falls through to
  // `rotateRefresh` below regardless of ownership, so the reuse-detection
  // cascade there still fires no matter who presents it.
  final live = await tokenStore.lookupRefresh(refreshToken);
  if (live != null && live.clientId != client.clientId) {
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  }

  final requestedScopes =
      form['scope']?.split(' ').where((s) => s.isNotEmpty).toSet();

  try {
    final issued = await tokenStore.rotateRefresh(
      refreshToken,
      scopes: requestedScopes,
    );
    return _tokenResponse(issued);
  } on TokenNotFoundException {
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  } on RefreshReuseException {
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  } on ScopeWideningException {
    return oauthError(HttpStatus.badRequest, 'invalid_scope');
  }
}

Response _tokenResponse(IssuedTokens issued) {
  return Response.json(
    headers: kNoStoreHeaders,
    body: {
      'access_token': issued.accessToken,
      'token_type': 'Bearer',
      'expires_in': issued.expiresIn,
      'refresh_token': issued.refreshToken,
      'scope': (issued.scopes.toList()..sort()).join(' '),
    },
  );
}
