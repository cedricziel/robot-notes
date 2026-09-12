import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/oauth/client_auth.dart';
import 'package:server/src/oauth/form_body.dart';
import 'package:server/src/oauth/oauth_response.dart';
import 'package:server/src/oauth/token_store.dart';

/// `POST /oauth/revoke` — invalidates an access or refresh token.
/// Revoking a refresh token invalidates its whole grant (the refresh
/// token and every access token minted from it). Per RFC 7009 §2.1, the
/// authenticated client may only revoke tokens issued to itself; revoking
/// another client's token is a silent no-op (still 200, per RFC 7009's
/// requirement that revocation never leaks whether a token exists).
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

  final token = form['token'];
  if (token == null || token.isEmpty) {
    return oauthError(HttpStatus.badRequest, 'invalid_request');
  }

  await context.read<TokenStore>().revokeToken(
        token,
        clientId: client.clientId,
      );
  return Response(headers: kNoStoreHeaders);
}
