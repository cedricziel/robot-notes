import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/tags.dart';

/// `POST /notes/{id}/append` — append text to the end of a note as a safe
/// server-side read-modify-write. REST twin of the MCP `append_to_note`
/// tool: both call [NoteWriteService.append], so semantics (newline
/// handling, retry-on-version-race, lock enforcement, `changed` broadcast)
/// are identical.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

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
  final content = raw['content'];
  if (content is! String || content.trim().isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'validation_failed',
        'message': 'content is required and must be a non-empty string',
      },
    );
  }

  final actor = context.read<Actor>();
  final writes = context.read<NoteWriteService>();

  try {
    final updated = await writes.append(
      id: id,
      text: content,
      actor: actor.name,
    );
    return Response.json(
      body: {
        'id': updated.id,
        'title': updated.title,
        'path': updated.path,
        'content': updated.content,
        'version': updated.version,
        'created_at': updated.createdAt.toUtc().toIso8601String(),
        'updated_at': updated.updatedAt.toUtc().toIso8601String(),
        'tags':
            computeTags(extra: updated.extra, content: updated.content).toList()
              ..sort(),
      },
    );
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  } on LockedException catch (e) {
    return Response.json(
      statusCode: HttpStatus.locked,
      body: {
        'error': 'locked',
        'lock': {
          'holder': e.current.holder,
          'expires_at': e.current.expiresAt.toUtc().toIso8601String(),
        },
      },
    );
  } on VersionConflictException catch (e) {
    final current = e.current;
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: {
        'error': 'version_conflict',
        'current': {
          'id': current.id,
          'title': current.title,
          'path': current.path,
          'content': current.content,
          'version': current.version,
          'created_at': current.createdAt.toUtc().toIso8601String(),
          'updated_at': current.updatedAt.toUtc().toIso8601String(),
          'tags': computeTags(extra: current.extra, content: current.content)
              .toList()
            ..sort(),
        },
      },
    );
  }
}
