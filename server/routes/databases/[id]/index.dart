import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/databases/definition.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';
import 'package:shared/shared.dart';

/// `GET /databases/{id}` — the full definition.
/// `PUT /databases/{id}` — replaces `source`/`properties`/`views` (any
///                          supplied section wholesale), with `If-Match`.
Future<Response> onRequest(RequestContext context, String id) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _read(context, id);
    case HttpMethod.put:
      return _update(context, id);
    case HttpMethod.delete:
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

Response _read(RequestContext context, String id) {
  final registry = context.read<DatabaseRegistry>();
  final def = registry.get(id);
  if (def == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }
  return Response.json(body: def.toJson());
}

Future<Response> _update(RequestContext context, String id) async {
  final ifMatchRaw = context.request.headers['if-match'];
  if (ifMatchRaw == null || ifMatchRaw.isEmpty) {
    return Response.json(
      statusCode: 428,
      body: const {
        'error': 'precondition_required',
        'message': 'PUT /databases/{id} requires an If-Match header',
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

  DatabaseSource? source;
  Map<String, PropertyDefinition>? properties;
  List<ViewDefinition>? views;
  try {
    if (raw.containsKey('source') && raw['source'] != null) {
      source = DatabaseSource.fromJson(
          (raw['source'] as Map).cast<String, dynamic>());
    }
    if (raw.containsKey('properties') && raw['properties'] != null) {
      final propertiesJson = (raw['properties'] as Map).cast<String, dynamic>();
      properties = {
        for (final entry in propertiesJson.entries)
          entry.key: PropertyDefinition.fromJson(
            (entry.value as Map).cast<String, dynamic>(),
          ),
      };
    }
    if (raw.containsKey('views') && raw['views'] != null) {
      views = [
        for (final v in raw['views'] as List)
          ViewDefinition.fromJson((v as Map).cast<String, dynamic>()),
      ];
    }
  } on Object {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'validation_failed',
        'message': 'source, properties, or views is malformed',
      },
    );
  }

  final actor = context.read<Actor>();
  final writes = context.read<NoteWriteService>();
  try {
    final updated = await writes.updateDatabase(
      id: id,
      ifMatch: ifMatch,
      actor: actor.name,
      source: source,
      properties: properties,
      views: views,
    );
    final def = parseDatabaseDefinition(
      id: updated.id,
      title: updated.title,
      path: updated.path,
      extra: updated.extra,
      version: updated.version,
      createdAt: updated.createdAt,
      updatedAt: updated.updatedAt,
    );
    return Response.json(body: def.toJson());
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  } on DefinitionValidationException catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'validation_failed',
        'message': e.violations.join('; '),
      },
    );
  } on VersionConflictException {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: const {'error': 'version_conflict'},
    );
  } on PathConflictException {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: const {'error': 'path_conflict'},
    );
  }
}
