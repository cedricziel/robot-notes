import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:logging/logging.dart';
import 'package:server/src/oauth/client_auth.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/form_body.dart';
import 'package:server/src/oauth/oauth_records.dart';
import 'package:server/src/oauth/oauth_response.dart';
import 'package:server/src/oauth/pkce.dart';
import 'package:server/src/oauth/token_store.dart';

final Logger _log = Logger('oauth.token');

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
  } on MalformedFormBodyException {
    return oauthError(HttpStatus.badRequest, 'invalid_request');
  }

  // Client authentication is checked before any grant_type validation, so
  // an unauthenticated caller can't distinguish "unknown client" from
  // "known client, bad grant_type" by watching which error code comes
  // back, and never learns anything about a grant's shape before proving
  // it owns the client.
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

  final grantType = form['grant_type'];
  if (grantType == null || grantType.isEmpty) {
    return oauthError(HttpStatus.badRequest, 'invalid_request');
  }
  if (grantType != 'authorization_code' && grantType != 'refresh_token') {
    return oauthError(HttpStatus.badRequest, 'unsupported_grant_type');
  }
  if (!client.grantTypes.contains(grantType)) {
    return oauthError(HttpStatus.badRequest, 'unauthorized_client');
  }

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

  final requestedResource = form['resource'];

  // Validation and token issuance both run inside the callback, while
  // CodeStore still holds the per-code mutex. That closes a race where a
  // concurrent replay of the same code could call `revokeGrant` (below)
  // before this exchange's tokens exist, leaving them live: the replay
  // now blocks until this callback — including `TokenStore.issue` — has
  // fully finished.
  try {
    return await context.read<CodeStore>().consume(code, (record) async {
      final mismatched = record.clientId != client.clientId ||
          record.redirectUri != redirectUri ||
          !pkceVerify(challenge: record.codeChallenge, verifier: verifier) ||
          (requestedResource != null && requestedResource != record.resource);
      if (mismatched) {
        return oauthError(HttpStatus.badRequest, 'invalid_grant');
      }

      final tokenStore = context.read<TokenStore>();
      // A failure here (e.g. a filesystem error) can strike after the
      // access token file is already written but before the response is
      // built, leaving a half-issued grant with no refresh token minted
      // for it. Revoke whatever was written before letting the error
      // propagate, rather than leaving it live and unreachable.
      try {
        final issued = await tokenStore.issue(
          clientId: client.clientId,
          actor: record.actor,
          scopes: record.scopes,
          resource: record.resource,
          grantId: record.grantId,
          withRefresh: client.grantTypes.contains('refresh_token'),
        );
        return _tokenResponse(issued);
      } on Object {
        await tokenStore.revokeGrant(record.grantId);
        rethrow;
      }
    });
  } on CodeReusedException catch (e) {
    _log.warning(
      'Authorization code reused for grant ${e.grantId}; revoking',
    );
    await context.read<TokenStore>().revokeGrant(e.grantId);
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  } on CodeNotFoundException {
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  } on Object catch (e, st) {
    _log.severe('Authorization code exchange failed', e, st);
    return oauthError(HttpStatus.internalServerError, 'server_error');
  }
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

  // An empty or whitespace-only `scope` is treated as absent — the grant
  // keeps its existing scopes — rather than as a request to narrow to no
  // scopes at all.
  final scopeParam = form['scope'];
  final requestedScopes = (scopeParam == null || scopeParam.trim().isEmpty)
      ? null
      : scopeParam.split(' ').where((s) => s.isNotEmpty).toSet();

  try {
    final issued = await tokenStore.rotateRefresh(
      refreshToken,
      scopes: requestedScopes,
    );
    return _tokenResponse(issued);
  } on TokenNotFoundException {
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  } on RefreshReuseException catch (e) {
    _log.warning(
      'Rotated refresh token reused for grant ${e.grantId}; family revoked',
    );
    return oauthError(HttpStatus.badRequest, 'invalid_grant');
  } on ScopeWideningException {
    return oauthError(HttpStatus.badRequest, 'invalid_scope');
  }
}

// `refresh_token` is included only when `issued.refreshToken` is
// non-null: whether a refresh token was minted at all is decided by the
// `withRefresh` passed to `TokenStore.issue`/`rotateRefresh`, not by this
// response shaping — a client not registered for the refresh_token grant
// never has one persisted in the first place, so there is nothing to
// withhold here.
Response _tokenResponse(IssuedTokens issued) {
  return Response.json(
    headers: kNoStoreHeaders,
    body: {
      'access_token': issued.accessToken,
      'token_type': 'Bearer',
      'expires_in': issued.expiresIn,
      if (issued.refreshToken != null) 'refresh_token': issued.refreshToken,
      'scope': (issued.scopes.toList()..sort()).join(' '),
      'actor': issued.actor,
    },
  );
}
