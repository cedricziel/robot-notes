import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/attachments.dart';
import 'package:server/src/config.dart';

/// `POST /notes/attachments` — uploads a non-note file into the vault's
/// folder structure. Accepts `multipart/form-data` with a `path` field
/// (the target folder) and a `file` field (the upload). Rejects a
/// request over the configured max size with `413`, and a filename
/// collision with `409` — no silent overwrite, no auto-renaming.
///
/// `dart_frog build` prints a "Route conflict" warning naming this file
/// and the sibling `[...path].dart` catch-all, since a catch-all can in
/// principle also match zero extra segments. Verified benign at runtime:
/// the literal `index.dart` route wins for the exact `/notes/attachments`
/// path (a `GET` there correctly 405s instead of falling through to the
/// catch-all), so `POST` here and `GET /notes/attachments/{path}` in
/// `[...path].dart` do not actually collide.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final config = context.read<Config>();

  // Fast pre-check on the client-declared size before spending any work
  // parsing the body — not authoritative (see the streaming check in
  // AttachmentStore.write below), but avoids buffering a body we already
  // know is too large.
  final declaredLength = int.tryParse(
    context.request.headers['content-length'] ?? '',
  );
  if (declaredLength != null && declaredLength > config.maxUploadSizeBytes) {
    return Response.json(
      statusCode: HttpStatus.requestEntityTooLarge,
      body: const {'error': 'payload_too_large'},
    );
  }

  final FormData formData;
  try {
    formData = await context.request.formData();
  } on Object {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'request body must be multipart/form-data',
      },
    );
  }

  final path = formData.fields['path'];
  if (path == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'bad_request', 'message': 'path is required'},
    );
  }
  final file = formData.files['file'];
  if (file == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'file is required',
      },
    );
  }

  final store = context.read<AttachmentStore>();
  try {
    final result = await store.write(
      path: path,
      filename: file.name,
      bytes: file.openRead(),
      maxBytes: config.maxUploadSizeBytes,
      contentType: file.contentType.mimeType,
    );
    return Response.json(
      statusCode: HttpStatus.created,
      body: {
        'path': result.path,
        'filename': result.filename,
        'size': result.size,
        'content_type': result.contentType,
      },
    );
  } on InvalidPathException catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'bad_request', 'message': e.message},
    );
  } on AttachmentCollisionException {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: const {'error': 'path_conflict'},
    );
  } on AttachmentTooLargeException {
    return Response.json(
      statusCode: HttpStatus.requestEntityTooLarge,
      body: const {'error': 'payload_too_large'},
    );
  }
}
