import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';

/// `GET /notes`  — paginated listing of note metadata (no content).
/// `POST /notes` — create a new note.
Future<Response> onRequest(RequestContext context) async {
  final method = context.request.method;
  switch (method) {
    case HttpMethod.get:
      return _list(context);
    case HttpMethod.post:
      return _create(context);
    case HttpMethod.delete:
    case HttpMethod.head:
    case HttpMethod.options:
    case HttpMethod.patch:
    case HttpMethod.put:
      return Response.json(
        statusCode: HttpStatus.methodNotAllowed,
        body: const {'error': 'method_not_allowed'},
      );
  }
}

Response _list(RequestContext context) {
  final index = context.read<MetaIndex>();
  final query = context.request.uri.queryParameters;
  final after = query['after'];
  final rawLimit = query['limit'];

  int? parsedLimit;
  if (rawLimit != null) {
    parsedLimit = int.tryParse(rawLimit);
    if (parsedLimit == null || parsedLimit <= 0) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: const {
          'error': 'bad_request',
          'message': 'limit must be a positive integer',
        },
      );
    }
  }

  final effectiveLimit = (parsedLimit ?? kDefaultPageSize).clamp(
    1,
    kMaxPageSize,
  );
  final page = index.page(after: after, limit: effectiveLimit);

  return Response.json(
    body: {
      'items': [
        for (final s in page.items)
          {
            'id': s.id,
            'title': s.title,
            'version': s.version,
            'created_at': s.createdAt.toUtc().toIso8601String(),
            'updated_at': s.updatedAt.toUtc().toIso8601String(),
          },
      ],
      'limit': effectiveLimit,
      'next_cursor': page.nextCursor,
    },
  );
}

Future<Response> _create(RequestContext context) async {
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

  final actor = context.read<Actor>();
  final writes = context.read<NoteWriteService>();
  final note = await writes.create(
    title: title,
    content: content,
    actor: actor.name,
  );

  return Response.json(
    statusCode: HttpStatus.created,
    body: {
      'id': note.id,
      'title': note.title,
      'content': note.content,
      'version': note.version,
      'created_at': note.createdAt.toUtc().toIso8601String(),
      'updated_at': note.updatedAt.toUtc().toIso8601String(),
    },
  );
}
