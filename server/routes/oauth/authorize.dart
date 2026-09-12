import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:logging/logging.dart';
import 'package:server/src/config.dart';
import 'package:server/src/constant_time.dart';
import 'package:server/src/oauth/authorize_request.dart';
import 'package:server/src/oauth/consent_page.dart';
import 'package:server/src/oauth/consent_throttle.dart';
import 'package:server/src/oauth/error_page.dart';
import 'package:server/src/oauth/form_body.dart';
import 'package:server/src/oauth/oauth_records.dart';

final Logger _log = Logger('oauth.authorize');

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
    return oauthErrorPage('Malformed query string.');
  }
  final validation = await validateAuthorizeRequest(context, params);
  return switch (validation) {
    AuthorizeClientError(:final message) => oauthErrorPage(message),
    AuthorizeRedirectError(:final redirectUri, :final error, :final state) =>
      _redirectWithError(redirectUri, error: error, state: state),
    AuthorizeValid(:final client, :final redirectUri, :final scopes) =>
      _renderConsent(
        context: context,
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
    return oauthErrorPage(
      'Request body must be application/x-www-form-urlencoded.',
    );
  } on MalformedFormBodyException {
    return oauthErrorPage('Malformed request body.');
  }

  final validation = await validateAuthorizeRequest(context, form);
  return switch (validation) {
    AuthorizeClientError(:final message) => oauthErrorPage(message),
    AuthorizeRedirectError(:final redirectUri, :final error, :final state) =>
      _redirectWithError(redirectUri, error: error, state: state),
    final AuthorizeValid valid => _submitConsent(
        context,
        valid: valid,
        form: form,
      ),
  };
}

Future<Response> _submitConsent(
  RequestContext context, {
  required AuthorizeValid valid,
  required Map<String, String> form,
}) async {
  final throttle = context.read<ConsentThrottle>();
  if (throttle.isBlocked) {
    return oauthErrorPage(
      'Too many failed attempts. Try again later.',
      statusCode: HttpStatus.tooManyRequests,
    );
  }

  final config = context.read<Config>();
  final apiKey = form['api_key'] ?? '';
  if (!constantTimeEquals(config.apiKey, apiKey)) {
    _log.warning(
      'Incorrect API key submitted for client ${valid.client.clientId}',
    );
    throttle.recordFailure(valid.client.clientId);
    return _renderConsent(
      context: context,
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

Response _renderConsent({
  required RequestContext context,
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
    oidcConfigured: context.read<Config>().oidc != null,
  );
  return Response(
    body: html,
    headers: kOAuthHtmlHeaders,
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
