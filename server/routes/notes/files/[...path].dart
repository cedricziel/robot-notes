import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mime/mime.dart';
import 'package:server/src/note_path.dart';
import 'package:server/src/storage.dart';

/// `GET /notes/files/{path}` — streams back the raw bytes of a
/// previously uploaded file, resolving `Content-Type` from the
/// filename's extension. Responds `404` when nothing exists at [path].
///
/// See `index.dart`'s doc comment for why `dart_frog build`'s
/// route-conflict warning naming this file is benign.
Future<Response> onRequest(RequestContext context, String path) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final List<String> segments;
  try {
    segments = sanitizedPathSegments(path);
  } on InvalidPathException {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'bad_request', 'message': 'invalid path'},
    );
  }
  if (segments.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }

  final storage = context.read<Storage>();
  final relFile = segments.join('/');
  final file = File('${storage.contentDir.path}/$relFile');
  if (!file.existsSync()) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }

  return Response.stream(
    body: file.openRead(),
    headers: {
      HttpHeaders.contentTypeHeader:
          lookupMimeType(relFile) ?? 'application/octet-stream',
    },
  );
}
