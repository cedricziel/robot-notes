import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';

/// Sorts [tags] ascending, case-insensitively, for a deterministic list
/// response (a `Set` has no inherent order).
List<String> _sortedTags(Set<String> tags) {
  final sorted = tags.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return sorted;
}

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
  final sort = query['sort'] ?? kSortId;
  final pathPrefix = query['path'];
  final tag = query['tag'];

  if (!kSupportedSorts.contains(sort)) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'bad_request', 'message': kSortErrorMessage},
    );
  }

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

  final MetaIndexPage page;
  try {
    page = index.page(
      after: after,
      limit: effectiveLimit,
      sort: sort,
      pathPrefix: pathPrefix,
      tag: tag,
    );
  } on InvalidCursorException {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'after is not a valid cursor for this sort',
      },
    );
  }

  return Response.json(
    body: {
      'items': [
        for (final s in page.items)
          {
            'id': s.id,
            'title': s.title,
            'path': s.path,
            'version': s.version,
            'created_at': s.createdAt.toUtc().toIso8601String(),
            'updated_at': s.updatedAt.toUtc().toIso8601String(),
            'excerpt': s.excerpt,
            'tags': _sortedTags(s.tags),
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
  final path = (pathRaw as String?) ?? '';

  final actor = context.read<Actor>();
  final writes = context.read<NoteWriteService>();
  try {
    final note = await writes.create(
      title: title,
      content: content,
      actor: actor.name,
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
