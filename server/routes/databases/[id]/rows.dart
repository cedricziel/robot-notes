import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/databases/note_properties.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/tags.dart';

/// `POST /databases/{id}/rows` — creates a new row of database [id]. See
/// the `databases` spec's "Creating a row creates a note with validated
/// properties" requirement.
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

  final title = raw['title'];
  if (title is! String || title.trim().isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'title is required and must be a non-empty string',
      },
    );
  }
  final propertiesRaw = raw['properties'];
  if (propertiesRaw != null && propertiesRaw is! Map) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'properties must be an object when provided',
      },
    );
  }
  final properties = ((propertiesRaw as Map<String, dynamic>?) ?? const {})
      .cast<String, Object?>();
  final contentRaw = raw['content'];
  final content = contentRaw is String ? contentRaw : '';
  final path = raw['path'] as String?;

  final actor = context.read<Actor>();
  final writes = context.read<NoteWriteService>();
  try {
    final note = await writes.createRow(
      databaseId: id,
      title: title,
      actor: actor.name,
      properties: properties,
      content: content,
      path: path,
    );
    return Response.json(
      statusCode: HttpStatus.created,
      body: {
        'id': note.id,
        'title': note.title,
        'path': note.path,
        'content': note.content,
        'version': note.version,
        'created_at': note.createdAt.toUtc().toIso8601String(),
        'updated_at': note.updatedAt.toUtc().toIso8601String(),
        'tags': computeTags(extra: note.extra, content: note.content).toList()
          ..sort(),
        'properties': propertiesOf(note.extra),
      },
    );
  } on DatabaseNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  } on PathOutsideSourceException catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'validation_failed',
        'message': e.toString(),
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
  } on PathConflictException {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: const {'error': 'path_conflict'},
    );
  } on InvalidPathException catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'bad_request', 'message': e.message},
    );
  }
}
