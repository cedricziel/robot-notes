import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';

/// `GET /notes/{id}`    — read a single note (with optional lock state).
/// `PUT /notes/{id}`    — replace a note's title/content (If-Match required).
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
        'content': note.content,
        'version': note.version,
        'created_at': note.createdAt.toUtc().toIso8601String(),
        'updated_at': note.updatedAt.toUtc().toIso8601String(),
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

  final storage = context.read<Storage>();
  final index = context.read<MetaIndex>();

  try {
    final updated = await storage.update(
      id: id,
      title: title,
      content: content,
      ifMatch: ifMatch,
    );
    index.upsert(updated.toSummary());
    return Response.json(
      body: {
        'id': updated.id,
        'title': updated.title,
        'content': updated.content,
        'version': updated.version,
        'created_at': updated.createdAt.toUtc().toIso8601String(),
        'updated_at': updated.updatedAt.toUtc().toIso8601String(),
      },
    );
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
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
          'content': current.content,
          'version': current.version,
          'created_at': current.createdAt.toUtc().toIso8601String(),
          'updated_at': current.updatedAt.toUtc().toIso8601String(),
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

  final storage = context.read<Storage>();
  final index = context.read<MetaIndex>();
  try {
    await storage.delete(id);
    index.remove(id);
    return Response(statusCode: HttpStatus.noContent);
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }
}
