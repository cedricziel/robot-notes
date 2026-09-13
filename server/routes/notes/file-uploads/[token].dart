import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/config.dart';
import 'package:server/src/upload_sessions.dart';

/// `PUT /notes/file-uploads/{token}` — completes a two-phase upload
/// reserved by the MCP `request_upload` tool, accepting the raw request
/// body as the file's bytes (not multipart). Authenticated by possession
/// of a valid, unexpired, not-yet-completed [token] alone — see
/// `auth_middleware.dart`'s exemption for this route and
/// `add-file-upload`'s design.md for why.
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.put) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final config = context.read<Config>();
  final declaredLength = int.tryParse(
    context.request.headers['content-length'] ?? '',
  );
  if (declaredLength != null && declaredLength > config.maxUploadSizeBytes) {
    return Response.json(
      statusCode: HttpStatus.requestEntityTooLarge,
      body: const {'error': 'payload_too_large'},
    );
  }

  final sessions = context.read<UploadSessionStore>();
  final contentType = context.request.headers['content-type'];
  try {
    final result = await sessions.complete(
      token: token,
      bytes: context.request.bytes(),
      contentType: contentType,
    );
    return Response.json(
      body: {
        'token': token,
        'size': result.size,
        'content_type': result.contentType,
        'expires_at': result.expiresAt.toUtc().toIso8601String(),
      },
    );
  } on UploadSessionNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  } on FileTooLargeException {
    return Response.json(
      statusCode: HttpStatus.requestEntityTooLarge,
      body: const {'error': 'payload_too_large'},
    );
  }
}
