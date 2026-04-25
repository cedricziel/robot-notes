import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/invite_store.dart';

/// `DELETE /invites/{token}` — revoke (delete) an invite. Returns 204 on
/// success, 404 if no such invite exists. All other methods are 405.
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.delete) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }
  final store = context.read<InviteStore>();
  try {
    await store.revoke(token);
    return Response(statusCode: HttpStatus.noContent);
  } on InviteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'invite_not_found'},
    );
  }
}
