import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/storage.dart';

/// Inspects current or retained accepted block identity metadata.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }
  final rawVersion = context.request.uri.queryParameters['version'];
  final version = rawVersion == null ? null : int.tryParse(rawVersion);
  if (rawVersion != null && (version == null || version < 1)) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'bad_request'},
    );
  }
  try {
    final map =
        await context.read<Storage>().readBlockMap(id, version: version);
    return Response.json(body: {'id': id, ...map.toJson()});
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  } on BlockMapUnavailableException catch (e) {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: {'error': e.stale ? 'block_map_stale' : 'block_map_unavailable'},
    );
  }
}
