import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';

/// `GET /notes/tree`  — the vault's folder hierarchy, one entry per
/// distinct folder that either directly contains at least one note or
/// was explicitly created empty (see `POST`), with a direct-note count.
/// Lets the sidebar render a folder tree without paginating every note
/// via `GET /notes`.
///
/// `POST /notes/tree` — creates an empty folder (and any missing
/// intermediate folders) at the given `path`, persisted via a marker
/// file so it survives a restart even with no notes in it. Idempotent:
/// a path that already resolves to an existing folder (with notes, a
/// marker, or both) responds 200 with its current state rather than an
/// error.
Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _tree(context);
    case HttpMethod.post:
      return _createFolder(context);
    default:
      return Response.json(
        statusCode: HttpStatus.methodNotAllowed,
        body: const {'error': 'method_not_allowed'},
      );
  }
}

Response _tree(RequestContext context) {
  final index = context.read<MetaIndex>();
  final storage = context.read<Storage>();
  final noteCounts = <String, int>{};
  for (final summary in index.all) {
    noteCounts.update(summary.path, (n) => n + 1, ifAbsent: () => 1);
  }
  final fileCounts = <String, int>{};
  for (final file in storage.files) {
    final folder = file.relativePath.contains('/')
        ? file.relativePath.substring(0, file.relativePath.lastIndexOf('/'))
        : '';
    fileCounts.update(folder, (n) => n + 1, ifAbsent: () => 1);
  }
  final paths = <String>{
    ...noteCounts.keys,
    ...index.emptyFolders,
    ...fileCounts.keys,
  }.toList()
    ..sort();

  return Response.json(
    body: {
      'folders': [
        for (final path in paths)
          {
            'path': path,
            'note_count': noteCounts[path] ?? 0,
            'file_count': fileCounts[path] ?? 0,
          },
      ],
    },
  );
}

Future<Response> _createFolder(RequestContext context) async {
  final dynamic raw;
  try {
    raw = await context.request.json();
  } on FormatException {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'request body must be JSON',
      },
    );
  }
  if (raw is! Map<String, dynamic>) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'request body must be a JSON object',
      },
    );
  }
  final path = raw['path'];
  if (path is! String || path.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'path is required and must be a non-empty string',
      },
    );
  }

  final storage = context.read<Storage>();
  final index = context.read<MetaIndex>();
  try {
    final result = await storage.createFolder(path);
    final noteCount = index.all.where((s) => s.path == result.path).length;
    // Only a folder with no notes is marker-backed on disk (per
    // Storage.createFolder); registering a note-backed folder here too
    // would leave it listed forever once its real notes are removed.
    if (noteCount == 0) index.registerEmptyFolder(result.path);
    return Response.json(
      statusCode: result.created ? HttpStatus.created : HttpStatus.ok,
      body: {'path': result.path, 'note_count': noteCount},
    );
  } on InvalidPathException catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'bad_request', 'message': e.message},
    );
  }
}
