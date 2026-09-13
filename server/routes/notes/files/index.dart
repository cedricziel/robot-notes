import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mime/mime.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/vault_files.dart';

/// `POST /notes/files` — uploads a non-note file into the vault's folder
/// structure directly (`multipart/form-data`: a `path` field naming the
/// target folder, a `file` field carrying the upload). Rejects a request
/// over the configured max size with `413`, and a name collision with
/// `409` — no silent overwrite, no auto-renaming.
///
/// `GET /notes/files?path=` — lists a folder's direct files (not
/// recursive into subfolders).
///
/// `dart_frog build` prints a "Route conflict" warning naming this file
/// and the sibling `[...path].dart` catch-all, since a catch-all can in
/// principle also match zero extra segments. Verified benign at runtime:
/// the literal `index.dart` route wins for the exact `/notes/files`
/// path, so this file's `GET`/`POST` and `GET /notes/files/{path}` in
/// `[...path].dart` do not actually collide.
Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _list(context);
    case HttpMethod.post:
      return _upload(context);
    default:
      return Response.json(
        statusCode: HttpStatus.methodNotAllowed,
        body: const {'error': 'method_not_allowed'},
      );
  }
}

Response _list(RequestContext context) {
  final storage = context.read<Storage>();
  final path = context.request.uri.queryParameters['path'] ?? '';
  final files = storage.filesIn(path)
    ..sort((a, b) => a.relativePath.compareTo(b.relativePath));

  return Response.json(
    body: {
      'items': [
        for (final file in files)
          {
            'path': path,
            'filename': _filenameOf(file.relativePath),
            'size': file.size,
            'content_type':
                lookupMimeType(file.relativePath) ?? 'application/octet-stream',
            'updated_at': file.updatedAt.toUtc().toIso8601String(),
          },
      ],
    },
  );
}

String _filenameOf(String relativePath) {
  final idx = relativePath.lastIndexOf('/');
  return idx < 0 ? relativePath : relativePath.substring(idx + 1);
}

Future<Response> _upload(RequestContext context) async {
  final config = context.read<Config>();

  // Fast pre-check on the client-declared size before spending any work
  // parsing the body — not authoritative (see the streaming check in
  // FileStore.write below), but avoids buffering a body we already know
  // is too large.
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
      body: const {'error': 'bad_request', 'message': 'file is required'},
    );
  }

  final store = context.read<FileStore>();
  final storage = context.read<Storage>();
  final clock = context.read<Clock>();
  try {
    final result = await store.write(
      path: path,
      filename: file.name,
      bytes: file.openRead(),
      maxBytes: config.maxUploadSizeBytes,
      contentType: file.contentType.mimeType,
    );
    storage.registerFile(
      StoredFile(
        relativePath: result.path.isEmpty
            ? result.filename
            : '${result.path}/${result.filename}',
        size: result.size,
        updatedAt: clock.nowUtc(),
      ),
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
  } on FileCollisionException {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: const {'error': 'path_conflict'},
    );
  } on FileTooLargeException {
    return Response.json(
      statusCode: HttpStatus.requestEntityTooLarge,
      body: const {'error': 'payload_too_large'},
    );
  }
}
