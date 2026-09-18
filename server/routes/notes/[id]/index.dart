import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/databases/definition.dart';
import 'package:server/src/databases/note_properties.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/tags.dart';

/// `GET /notes/{id}`    — read a single note (with optional lock state).
/// `PUT /notes/{id}`    — update a note's title/content/path (If-Match
///                        required; `title` and `path` default to their
///                        current value when omitted, `content` to `''`).
/// `DELETE /notes/{id}` — delete a note.
Future<Response> onRequest(RequestContext context, String id) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _read(context, id);
    case HttpMethod.put:
      return _update(context, id);
    case HttpMethod.delete:
      return _delete(context, id);
    case HttpMethod.head:
    case HttpMethod.options:
    case HttpMethod.patch:
    case HttpMethod.post:
      return Response.json(
        statusCode: HttpStatus.methodNotAllowed,
        body: const {'error': 'method_not_allowed'},
      );
  }
}

Future<Response> _read(RequestContext context, String id) async {
  final storage = context.read<Storage>();
  final lockManager = context.read<LockManager>();

  try {
    final note = await storage.read(id);
    final lock = lockManager.lockOf(id);
    return Response.json(
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
        if (isDatabaseDefinitionExtra(note.extra)) 'type': 'database',
        'lock': lock == null
            ? null
            : {
                'holder': lock.holder,
                'expires_at': lock.expiresAt.toUtc().toIso8601String(),
              },
      },
    );
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }
}

Future<Response> _update(RequestContext context, String id) async {
  final ifMatchRaw = context.request.headers['if-match'];
  if (ifMatchRaw == null || ifMatchRaw.isEmpty) {
    return Response.json(
      statusCode: 428,
      body: const {
        'error': 'precondition_required',
        'message': 'PUT /notes/{id} requires an If-Match header',
      },
    );
  }
  final ifMatch = int.tryParse(ifMatchRaw);
  if (ifMatch == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'If-Match must be an integer version',
      },
    );
  }

  final actor = context.read<Actor>();
  final lockManager = context.read<LockManager>();
  final activeLock = lockManager.lockOf(id);
  if (activeLock != null && activeLock.holder != actor.name) {
    return Response.json(
      statusCode: HttpStatus.locked,
      body: {
        'error': 'locked',
        'lock': {
          'holder': activeLock.holder,
          'expires_at': activeLock.expiresAt.toUtc().toIso8601String(),
        },
      },
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
  // `title` is optional (see API.md's `PUT /notes/{id}`: "Request (any of
  // `title`, `content`, `path`..."). When present it must be a non-empty
  // string; when omitted the note keeps its current title, the same
  // "unspecified means unchanged" rule `path` already follows below —
  // unlike `content`, which the documented contract deliberately blanks
  // out to `''` rather than preserving when omitted.
  final rawTitle = raw['title'];
  final String title;
  if (rawTitle == null) {
    final storage = context.read<Storage>();
    try {
      title = (await storage.read(id)).title;
    } on NoteNotFoundException {
      return Response.json(
        statusCode: HttpStatus.notFound,
        body: const {'error': 'not_found'},
      );
    }
  } else if (rawTitle is String && rawTitle.trim().isNotEmpty) {
    title = rawTitle;
  } else {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'title must be a non-empty string when provided',
      },
    );
  }
  final contentRaw = raw['content'];
  if (contentRaw != null && contentRaw is! String) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'content must be a string when provided',
      },
    );
  }
  final content = (contentRaw as String?) ?? '';
  final pathRaw = raw['path'];
  if (pathRaw != null && pathRaw is! String) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'path must be a string when provided',
      },
    );
  }
  final path = pathRaw as String?;
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
  final properties =
      (propertiesRaw as Map<String, dynamic>?)?.cast<String, Object?>();

  final writes = context.read<NoteWriteService>();

  try {
    final updated = await writes.update(
      id: id,
      title: title,
      content: content,
      ifMatch: ifMatch,
      actor: actor.name,
      path: path,
      properties: properties,
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

Future<Response> _delete(RequestContext context, String id) async {
  final actor = context.read<Actor>();
  final lockManager = context.read<LockManager>();
  final activeLock = lockManager.lockOf(id);
  if (activeLock != null && activeLock.holder != actor.name) {
    return Response.json(
      statusCode: HttpStatus.locked,
      body: {
        'error': 'locked',
        'lock': {
          'holder': activeLock.holder,
          'expires_at': activeLock.expiresAt.toUtc().toIso8601String(),
        },
      },
    );
  }

  final writes = context.read<NoteWriteService>();
  try {
    await writes.delete(id: id, actor: actor.name);
    return Response(statusCode: HttpStatus.noContent);
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }
}
