import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/databases/query.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/databases/validation.dart';
import 'package:server/src/meta_index.dart' hide InvalidCursorException;
import 'package:server/src/search_index.dart';
import 'package:shared/shared.dart';

/// Maximum accepted `limit`, per the `databases` spec's "Querying a
/// database returns rows with properties" requirement.
const int _kMaxLimit = 200;

/// `POST /databases/{id}/query` — see design.md's "REST surface" and the
/// `databases` spec's "Querying a database returns rows with properties"
/// requirement. Needs only `notes:read` (see `auth_middleware`'s per-route
/// override).
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final registry = context.read<DatabaseRegistry>();
  final def = registry.get(id);
  if (def == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }

  dynamic raw;
  try {
    raw = await context.request.json();
  } on FormatException {
    raw = <String, dynamic>{};
  }
  final body = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};

  ViewDefinition? view;
  final viewName = body['view'];
  if (viewName is String) {
    for (final v in def.views) {
      if (v.name.toLowerCase() == viewName.toLowerCase()) {
        view = v;
        break;
      }
    }
    if (view == null) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: const {
          'error': 'validation_failed',
          'message': 'unknown view',
        },
      );
    }
  } else if (def.views.isNotEmpty) {
    view = def.views.first;
  }

  Filter? filter;
  try {
    filter = body.containsKey('filter') && body['filter'] != null
        ? Filter.fromJson((body['filter'] as Map).cast<String, dynamic>())
        : view?.filter;
  } on Object catch (_) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'validation_failed', 'message': 'bad filter'},
    );
  }

  List<SortSpec> sort;
  try {
    sort = body.containsKey('sort') && body['sort'] != null
        ? [
            for (final s in body['sort'] as List)
              SortSpec.fromJson((s as Map).cast<String, dynamic>()),
          ]
        : (view?.sort ?? const []);
  } on Object {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'validation_failed', 'message': 'bad sort'},
    );
  }

  final groupBy = body.containsKey('group_by') && body['group_by'] != null
      ? body['group_by'] as String
      : view?.groupBy;

  if (filter != null) {
    final violation = _invalidFilterProperty(filter, def);
    if (violation != null) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: {'error': 'validation_failed', 'message': violation},
      );
    }
  }

  final limitRaw = body['limit'];
  var limit = 50;
  if (limitRaw != null) {
    if (limitRaw is! int || limitRaw < 1 || limitRaw > _kMaxLimit) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: const {
          'error': 'validation_failed',
          'message': 'limit must be an integer between 1 and $_kMaxLimit',
        },
      );
    }
    limit = limitRaw;
  }
  final after = body['after'] as String?;

  final searchIndex = context.read<SearchIndex>();
  final query = DatabaseQuery(searchIndex.rawDb);

  List<String>? groupByOptions;
  if (groupBy != null) {
    groupByOptions = def.properties[groupBy]?.options;
  }

  final QueryPage page;
  try {
    page = query.run(
      source: def.source,
      filter: filter,
      sort: sort,
      groupBy: groupBy,
      groupByOptions: groupByOptions,
      limit: limit,
      after: after,
      excludeIds: [def.id],
    );
  } on InvalidCursorException {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'validation_failed', 'message': 'bad cursor'},
    );
  }

  final metaIndex = context.read<MetaIndex>();

  return Response.json(
    body: {
      'items': [
        for (final row in page.items)
          _hydrate(row, def, metaIndex.get(row.id)?.version ?? 0).toJson(),
      ],
      'next_cursor': page.nextCursor,
      if (page.groups != null)
        'groups': [for (final g in page.groups!) g.toJson()],
    },
  );
}

/// Returns the first violation message found walking [filter] against
/// [def]'s declared properties/built-ins, or `null` if every condition
/// references a known property with an applicable operator.
String? _invalidFilterProperty(Filter filter, DatabaseDefinition def) {
  switch (filter) {
    case Condition c:
      final declared = def.properties[c.property];
      final type = declared?.type ?? builtinPropertyType(c.property);
      if (type == null) {
        return 'undeclared property "${c.property}"';
      }
      if (!applicableFilterOps(type).contains(c.op)) {
        return '${c.op.wire} is not applicable to "${c.property}"';
      }
      return null;
    case And(and: final children):
      for (final child in children) {
        final v = _invalidFilterProperty(child, def);
        if (v != null) return v;
      }
      return null;
    case Or(or: final children):
      for (final child in children) {
        final v = _invalidFilterProperty(child, def);
        if (v != null) return v;
      }
      return null;
  }
}

DatabaseRow _hydrate(QueryRow row, DatabaseDefinition def, int version) {
  final properties = <String, Object?>{};
  final invalid = <String>[];
  for (final entry in def.properties.entries) {
    final key = entry.key;
    if (!row.properties.containsKey(key)) continue;
    final value = row.properties[key];
    if (value == null) continue;
    final violations = validateProperties(
      [def],
      {key: value},
    );
    if (violations.isNotEmpty) {
      invalid.add(key);
    } else {
      properties[key] = value;
    }
  }
  return DatabaseRow(
    id: row.id,
    title: row.title,
    path: row.path,
    version: version,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    tags: row.tags,
    properties: properties,
    invalid: invalid,
  );
}
