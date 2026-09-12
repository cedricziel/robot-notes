import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/tags.dart';

/// `GET /tags` — every distinct tag across the vault (merging frontmatter
/// `tags` and inline `#tag` tokens per `notes-storage`), with its note
/// count, sorted by descending count (see `notes-api`).
///
/// Requires authentication like every other route under `/`: this file
/// isn't in `auth_middleware.dart`'s exemption list, so the root
/// middleware's `bearerAuth` already gates it — no extra check needed
/// here.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final index = context.read<MetaIndex>();
  final counts = aggregateTagCounts([
    for (final summary in index.all) summary.tags,
  ]);

  return Response.json(
    body: {
      'items': [
        for (final c in counts) {'tag': c.tag, 'count': c.count},
      ],
    },
  );
}
