import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/databases/definition.dart';
import 'package:server/src/databases/note_properties.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/tags.dart';

/// `PATCH /notes/{id}/properties` — sets/unsets frontmatter property keys
/// without touching the body. Needs no `If-Match` and ignores the editor
/// lock; see [NoteWriteService.patchProperties] and the `databases` spec's
/// "Property patches merge without If-Match and without touching the body"
/// requirement.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.patch) {
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

  final setRaw = raw['set'];
  if (setRaw != null && setRaw is! Map) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'set must be an object when provided',
      },
    );
  }
  final unsetRaw = raw['unset'];
  if (unsetRaw != null && unsetRaw is! List) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'unset must be a list when provided',
      },
    );
  }

  final set =
      ((setRaw as Map<String, dynamic>?) ?? const {}).cast<String, Object?>();
  final unset = ((unsetRaw as List<dynamic>?) ?? const [])
      .map((e) => e as String)
      .toSet();

  final actor = context.read<Actor>();
  final writes = context.read<NoteWriteService>();
  try {
    final updated = await writes.patchProperties(
      id: id,
      set: set,
      unset: unset,
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
        'properties': propertiesOf(updated.extra),
        if (isDatabaseDefinitionExtra(updated.extra)) 'type': 'database',
      },
    );
  } on PropertyValidationException catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'validation_failed',
        'message': e.violations.join('; '),
      },
    );
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }
}
