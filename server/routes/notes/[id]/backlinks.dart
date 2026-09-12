import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/backlinks.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';

/// `GET /notes/{id}/backlinks` — every note whose content contains a
/// parsed link resolving to `{id}`, most-recently-updated first.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  try {
    final entries = await computeBacklinks(
      targetId: id,
      metaIndex: context.read<MetaIndex>(),
      linkIndex: context.read<LinkIndex>(),
      storage: context.read<Storage>(),
    );
    return Response.json(
      body: {
        'items': [
          for (final entry in entries)
            {
              'id': entry.id,
              'title': entry.title,
              'snippet': entry.snippet,
            },
        ],
      },
    );
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }
}
