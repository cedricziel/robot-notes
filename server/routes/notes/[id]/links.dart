import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/meta_index.dart';

/// `GET /notes/{id}/links` — a note's outgoing `[[wikilinks]]`, with each
/// one's resolution state against the current title index.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final metaIndex = context.read<MetaIndex>();
  if (metaIndex.get(id) == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  }

  final linkIndex = context.read<LinkIndex>();
  // Resolution happens here, at request time, rather than being cached on
  // the edge — that's what lets a phantom link start showing as resolved
  // the moment a matching title is created, without the linking note ever
  // being re-saved (see `links` spec).
  final items = [
    for (final edge in linkIndex.outgoing(id))
      () {
        final resolvedId = metaIndex.resolveTitle(edge.targetTitle);
        return {
          'title': edge.targetTitle,
          'resolved': resolvedId != null,
          if (resolvedId != null) 'id': resolvedId,
        };
      }(),
  ];

  return Response.json(body: {'items': items});
}
