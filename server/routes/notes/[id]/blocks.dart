import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_reads.dart';
import 'package:server/src/storage.dart';

/// Inspects current or retained accepted block identity metadata.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }
  final rawVersion = context.request.uri.queryParameters['version'];
  final version = rawVersion == null ? null : int.tryParse(rawVersion);
  if (rawVersion != null && (version == null || version < 1)) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'bad_request'},
    );
  }
  try {
    if (version != null) {
      final reads = context.read<KnowledgeReadService>();
      final current = await reads.writes.knowledgeTarget(id);
      final records = await context.read<Storage>().revisions(id);
      final matching = records.where((record) => record['version'] == version);
      if (matching.isEmpty) throw NoteNotFoundException(id);
      final record = matching.single;
      final path =
          record['path'] as String? ?? record['previous_path'] as String?;
      final metadataPath = parseFrontmatter(record['markdown'] as String)
          .metadata['path'] as String?;
      final retainedFolder = metadataPath ??
          (path == null || !path.contains('/')
              ? ''
              : path.substring(0, path.lastIndexOf('/')));
      reads.authorization.requireHistoricalRead(
        currentKnowledgePrincipal,
        id,
        retainedFolder,
        current.path,
      );
    }
    final map =
        await context.read<Storage>().readBlockMap(id, version: version);
    return Response.json(body: {'id': id, ...map.toJson()});
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  } on BlockMapUnavailableException catch (e) {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: {'error': e.stale ? 'block_map_stale' : 'block_map_unavailable'},
    );
  }
}
