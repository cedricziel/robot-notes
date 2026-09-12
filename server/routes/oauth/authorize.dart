import 'dart:io';
import 'dart:math';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/config.dart';
import 'package:server/src/constant_time.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/consent_page.dart';
import 'package:server/src/oauth/form_body.dart';
import 'package:server/src/oauth/metadata.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/oauth_records.dart';
import 'package:server/src/public_url.dart';

/// Byte length for a minted `grant_id`: not a secret (it is stored
/// plaintext alongside codes and tokens to link a family for revocation),
/// but unpredictable so grant families cannot be enumerated.
const int _kGrantIdBytes = 16;

final Random _secureRandom = Random.secure();

/// `GET  /oauth/authorize` — validates the request and renders the
/// consent page.
/// `POST /oauth/authorize` — proves ownership with the API key and mints
/// an authorization code.
Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _get(context);
    case HttpMethod.post:
      return _post(context);
    case HttpMethod.delete:
    case HttpMethod.head:
    case HttpMethod.options:
    case HttpMethod.patch:
    case HttpMethod.put:
      return Response.json(
        statusCode: HttpStatus.methodNotAllowed,
        body: const {'error': 'method_not_allowed'},
      );
  }
}

Future<Response> _get(RequestContext context) async {
  final Map<String, String> params;
  try {
    params = context.request.uri.queryParameters;
  } on FormatException {
    return _errorPage('Malformed query string.');
  }
  final validation = await _validate(context, params);
  return switch (validation) {
    _ClientError(:final message) => _errorPage(message),
    _RedirectError(:final redirectUri, :final error, :final state) =>
      _redirectWithError(redirectUri, error: error, state: state),
    _Valid(:final client, :final redirectUri, :final scopes) => _renderConsent(
        client: client,
        redirectUri: redirectUri,
        params: params,
        scopes: scopes,
      ),
  };
}

Future<Response> _post(RequestContext context) async {
  final Map<String, String> form;
  try {
    form = await parseFormBody(context.request);
  } on UnsupportedFormContentTypeException {
    return _errorPage(
      'Request body must be application/x-www-form-urlencoded.',
    );
  } on MalformedFormBodyException {
    return _errorPage('Malformed request body.');
  }

  final validation = await _validate(context, form);
  return switch (validation) {
    _ClientError(:final message) => _errorPage(message),
    _RedirectError(:final redirectUri, :final error, :final state) =>
      _redirectWithError(redirectUri, error: error, state: state),
    final _Valid valid => _submitConsent(context, valid: valid, form: form),
  };
}

Future<Response> _submitConsent(
  RequestContext context, {
  required _Valid valid,
  required Map<String, String> form,
}) async {
  final config = context.read<Config>();
  final apiKey = form['api_key'] ?? '';
  if (!constantTimeEquals(config.apiKey, apiKey)) {
    return _renderConsent(
      client: valid.client,
      redirectUri: valid.redirectUri,
      params: form,
      scopes: valid.scopes,
      errorMessage: 'Incorrect API key.',
    );
  }

  final actorRaw = (form['actor'] ?? '').trim();
  final clientName = valid.client.clientName.trim();
  final actor = actorRaw.isNotEmpty
      ? actorRaw
      : (clientName.isNotEmpty ? clientName : 'mcp-client');

  final code = await context.read<CodeStore>().mint(
        clientId: valid.client.clientId,
        redirectUri: valid.redirectUri,
        codeChallenge: valid.codeChallenge,
        scopes: valid.scopes,
        resource: valid.resource,
        actor: actor,
        grantId: generateRandomToken(_secureRandom, _kGrantIdBytes),
      );

  final base = publicBaseUrl(context);
  final location = _appendQuery(valid.redirectUri, {
    'code': code,
    'iss': base,
    if (valid.state != null) 'state': valid.state!,
  });
  return Response(
    statusCode: HttpStatus.found,
    headers: {HttpHeaders.locationHeader: location.toString()},
  );
}

Response _renderConsent({
  required OAuthClient client,
  required String redirectUri,
  required Map<String, String> params,
  required Set<String> scopes,
  String? errorMessage,
}) {
  final html = renderConsentPage(
    ConsentPageParams(
      clientId: client.clientId,
      clientName: client.clientName,
      redirectUri: redirectUri,
      responseType: 'code',
      codeChallenge: params['code_challenge']!,
      codeChallengeMethod: params['code_challenge_method']!,
      scopes: scopes,
      state: params['state'],
      resource: params['resource'],
    ),
    errorMessage: errorMessage,
  );
  return Response(
    body: html,
    headers: _kConsentPageHeaders,
  );
}

Response _errorPage(String message) => Response(
      statusCode: HttpStatus.badRequest,
      body:
          '<!doctype html><html lang="en"><body><p>$message</p></body></html>',
      headers: _kConsentPageHeaders,
    );

const Map<String, String> _kConsentPageHeaders = {
  HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
  'Content-Security-Policy':
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
  'X-Frame-Options': 'DENY',
  HttpHeaders.cacheControlHeader: 'no-store',
};

Response _redirectWithError(
  String redirectUri, {
  required String error,
  String? state,
}) {
  final location = _appendQuery(redirectUri, {
    'error': error,
    if (state != null) 'state': state,
  });
  return Response(
    statusCode: HttpStatus.found,
    headers: {HttpHeaders.locationHeader: location.toString()},
  );
}

Uri _appendQuery(String uri, Map<String, String> extra) {
  final base = Uri.parse(uri);
  return base.replace(queryParameters: {...base.queryParameters, ...extra});
}

/// Outcome of validating an authorization request, shared by the GET and
/// POST handlers.
sealed class _Validation {
  const _Validation();
}

/// `client_id` is unknown, or `redirect_uri` was not registered for it:
/// the server cannot safely redirect, so it renders an HTML error page.
final class _ClientError extends _Validation {
  const _ClientError(this.message);
  final String message;
}

/// The client and redirect URI are known; a later check failed. Reported
/// via redirect, per the OAuth authorization-error convention.
final class _RedirectError extends _Validation {
  const _RedirectError({
    required this.redirectUri,
    required this.error,
    required this.state,
  });
  final String redirectUri;
  final String error;
  final String? state;
}

/// Every check passed.
final class _Valid extends _Validation {
  const _Valid({
    required this.client,
    required this.redirectUri,
    required this.codeChallenge,
    required this.scopes,
    required this.resource,
    required this.state,
  });
  final OAuthClient client;
  final String redirectUri;
  final String codeChallenge;
  final Set<String> scopes;
  final String resource;
  final String? state;
}

Future<_Validation> _validate(
  RequestContext context,
  Map<String, String> params,
) async {
  final clientId = params['client_id'];
  final redirectUri = params['redirect_uri'];
  if (clientId == null || redirectUri == null) {
    return const _ClientError('client_id and redirect_uri are required.');
  }

  final client = await context.read<ClientStore>().get(clientId);
  if (client == null) {
    return const _ClientError('Unknown client_id.');
  }
  if (!client.redirectUris.contains(redirectUri)) {
    return const _ClientError(
      'redirect_uri is not registered for this client.',
    );
  }

  final state = params['state'];

  if (!client.responseTypes.contains('code')) {
    return _RedirectError(
      redirectUri: redirectUri,
      error: 'unauthorized_client',
      state: state,
    );
  }

  if (params['response_type'] != 'code') {
    return _RedirectError(
      redirectUri: redirectUri,
      error: 'unsupported_response_type',
      state: state,
    );
  }

  final codeChallenge = params['code_challenge'];
  if (codeChallenge == null ||
      codeChallenge.isEmpty ||
      params['code_challenge_method'] != 'S256') {
    return _RedirectError(
      redirectUri: redirectUri,
      error: 'invalid_request',
      state: state,
    );
  }

  final scopeParam = params['scope'];
  final requestedScopes = (scopeParam == null || scopeParam.trim().isEmpty)
      ? kOAuthScopes.toSet()
      : scopeParam.split(' ').where((s) => s.isNotEmpty).toSet();
  if (requestedScopes.isEmpty ||
      !requestedScopes.every(kOAuthScopes.contains)) {
    return _RedirectError(
      redirectUri: redirectUri,
      error: 'invalid_scope',
      state: state,
    );
  }

  final canonicalResource = mcpResourceUrl(publicBaseUrl(context));
  final resourceParam = params['resource'];
  if (resourceParam != null && resourceParam != canonicalResource) {
    return _RedirectError(
      redirectUri: redirectUri,
      error: 'invalid_target',
      state: state,
    );
  }

  return _Valid(
    client: client,
    redirectUri: redirectUri,
    codeChallenge: codeChallenge,
    scopes: requestedScopes,
    resource: canonicalResource,
    state: state,
  );
}
