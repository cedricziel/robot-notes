import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/links.dart';
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

  final metaIndex = context.read<MetaIndex>();
  final target = metaIndex.get(id);
  if (target == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }

  final linkIndex = context.read<LinkIndex>();
  final storage = context.read<Storage>();

  // A source only counts if its link's target title currently resolves to
  // THIS id — with a duplicate title elsewhere, only the note that wins
  // resolution (MetaIndex.resolveTitle) is ever a valid link target, so
  // only its backlinks should list the source.
  final sourceIds = linkIndex
      .sourcesLinkingToTitle(target.title)
      .where((sourceId) => sourceId != id)
      .where((sourceId) => metaIndex.resolveTitle(target.title) == id);

  final entries = <MapEntry<NoteSummary, String>>[];
  for (final sourceId in sourceIds) {
    final summary = metaIndex.get(sourceId);
    if (summary == null) continue; // raced with a concurrent delete
    StoredNote source;
    try {
      source = await storage.read(sourceId);
    } on NoteNotFoundException {
      continue;
    }
    final match = parseLinks(source.content).firstWhere(
      (l) => l.targetTitle == target.title,
    );
    entries.add(MapEntry(summary, snippetAround(source.content, match)));
  }
  entries.sort((a, b) => b.key.updatedAt.compareTo(a.key.updatedAt));

  return Response.json(
    body: {
      'items': [
        for (final entry in entries)
          {
            'id': entry.key.id,
            'title': entry.key.title,
            'snippet': entry.value,
          },
      ],
    },
  );
}
