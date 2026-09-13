import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mime/mime.dart';
import 'package:server/src/attachments.dart';
import 'package:server/src/note_path.dart';

/// `GET /notes/attachments/{path}` — streams back a previously uploaded
/// attachment's raw bytes, with a `Content-Type` derived from the
/// filename's extension (falling back to `application/octet-stream` for
/// an unrecognized one). `404 Not Found` if no file exists at [path].
Future<Response> onRequest(RequestContext context, String path) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final List<String> segments;
  try {
    // Re-sanitizing is a no-op for a legitimately-stored path (it was
    // already sanitized this same way on upload) and is what rejects a
    // `..`-based traversal attempt in the URL, matching every other
    // path-addressed endpoint in this API.
    segments = sanitizedPathSegments(path);
  } on InvalidPathException catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'bad_request', 'message': e.message},
    );
  }
  if (segments.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }

  final store = context.read<AttachmentStore>();
  final relFile = segments.join('/');
  final file = File('${store.contentDir.path}/$relFile');
  if (!file.existsSync()) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }

  final contentType = lookupMimeType(relFile) ?? 'application/octet-stream';
  return Response.stream(
    body: file.openRead(),
    headers: {HttpHeaders.contentTypeHeader: contentType},
  );
}
