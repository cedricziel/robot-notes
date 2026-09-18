import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/databases/definition.dart';
import 'package:server/src/databases/query.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:shared/shared.dart';

/// `GET /databases`  — list every registered database, with `row_count`.
/// `POST /databases` — create a new database definition note.
Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
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
  final registry = context.read<DatabaseRegistry>();
  final searchIndex = context.read<SearchIndex>();
  final query = DatabaseQuery(searchIndex.rawDb);

  return Response.json(
    body: {
      'items': [
        for (final def in registry.all)
          {
            'id': def.id,
            'title': def.title,
            'path': def.path,
            'source': def.source.toJson(),
            'row_count':
                query.rowCount(source: def.source, excludeIds: [def.id]),
          },
      ],
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

  final DatabaseSource source;
  try {
    source = raw['source'] == null
        ? DatabaseSource.folder((raw['path'] as String?) ?? '')
        : DatabaseSource.fromJson(
            (raw['source'] as Map).cast<String, dynamic>(),
          );
  } on Object {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'source is malformed',
      },
    );
  }

  final Map<String, PropertyDefinition> properties;
  final List<ViewDefinition> views;
  try {
    final propertiesJson =
        (raw['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
    properties = {
      for (final entry in propertiesJson.entries)
        entry.key: PropertyDefinition.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        ),
    };
    final viewsJson = (raw['views'] as List?) ?? const [];
    views = [
      for (final v in viewsJson)
        ViewDefinition.fromJson((v as Map).cast<String, dynamic>()),
    ];
  } on Object {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'validation_failed',
        'message': 'properties or views is malformed',
      },
    );
  }

  final contentRaw = raw['content'];
  final content = contentRaw is String ? contentRaw : '';
  final path = (raw['path'] as String?) ?? '';

  final actor = context.read<Actor>();
  final writes = context.read<NoteWriteService>();
  try {
    final note = await writes.createDatabase(
      title: title,
      actor: actor.name,
      source: source,
      path: path,
      content: content,
      properties: properties,
      views: views,
    );
    final def = parseDatabaseDefinition(
      id: note.id,
      title: note.title,
      path: note.path,
      extra: note.extra,
      version: note.version,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
    );
    return Response.json(statusCode: HttpStatus.created, body: def.toJson());
  } on DefinitionValidationException catch (e) {
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
