import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';

/// Inspects, restores, or permanently purges retained accepted revisions.
Future<Response> onRequest(RequestContext context, String id) async {
  final storage = context.read<Storage>();
  final method = context.request.method;
  if (method == HttpMethod.get) {
    final target = await context.read<NoteWriteService>().knowledgeTarget(id);
    final authorization = context.read<NoteAuthorizationService>();
    final revisions = await storage.revisions(id);
    final visible = <Map<String, dynamic>>[];
    for (final revision in revisions) {
      final retained =
          revision['path'] as String? ?? revision['previous_path'] as String?;
      final metadataPath = parseFrontmatter(revision['markdown'] as String)
          .metadata['path'] as String?;
      final retainedFolder = metadataPath ??
          (retained == null || !retained.contains('/')
              ? ''
              : retained.substring(0, retained.lastIndexOf('/')));
      try {
        authorization.requireHistoricalRead(
          currentKnowledgePrincipal,
          id,
          retainedFolder,
          target.path,
        );
        visible.add(revision);
      } on KnowledgeAccessDeniedException {
        continue;
      }
    }
    return Response.json(body: {'revisions': visible});
  }
  if (method == HttpMethod.delete) {
    await context.read<NoteWriteService>().purgeHistory(id);
    return Response(statusCode: HttpStatus.noContent);
  }
  if (method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'method_not_allowed'},
    );
  }
  final actor = context.read<Actor>().name;
  final lock = context.read<LockManager>().lockOf(id);
  if (lock != null && lock.holder != actor) {
    return Response.json(statusCode: 423, body: {'error': 'locked'});
  }
  try {
    final raw = await context.request.json();
    if (raw is! Map<String, dynamic> ||
        raw['version'] is! int ||
        raw['if_match'] is! int ||
        (raw['version'] as int) < 1) {
      return Response.json(statusCode: 400, body: {'error': 'bad_request'});
    }
    final note = await context.read<NoteWriteService>().restoreRevision(
          id: id,
          version: raw['version'] as int,
          ifMatch: raw['if_match'] as int,
          actor: actor,
        );
    return Response.json(body: {'id': note.id, 'version': note.version});
  } on PropertyValidationException {
    return Response.json(
      statusCode: 422,
      body: {'error': 'invalid_properties'},
    );
  } on FormatException {
    return Response.json(statusCode: 400, body: {'error': 'bad_request'});
  } on NoteNotFoundException {
    return Response.json(statusCode: 404, body: {'error': 'not_found'});
  } on HistoryVersionConflictException catch (e) {
    return Response.json(
      statusCode: 409,
      body: {
        'error': 'version_conflict',
        'current_version': e.currentVersion,
      },
    );
  } on PathConflictException {
    return Response.json(statusCode: 409, body: {'error': 'path_conflict'});
  }
}
