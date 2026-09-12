import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/meta_index.dart';

/// `GET /notes/tree` — the vault's folder hierarchy, one entry per
/// distinct folder that directly contains at least one note, with a
/// direct-note count. Lets the sidebar render a folder tree without
/// paginating every note via `GET /notes`.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final index = context.read<MetaIndex>();
  final counts = <String, int>{};
  for (final summary in index.all) {
    counts.update(summary.path, (n) => n + 1, ifAbsent: () => 1);
  }
  final folders = counts.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  return Response.json(
    body: {
      'folders': [
        for (final entry in folders)
          {'path': entry.key, 'note_count': entry.value},
      ],
    },
  );
}
