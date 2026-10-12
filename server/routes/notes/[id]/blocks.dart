import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/proposals/proposal_service.dart';
import 'package:server/src/storage.dart';

/// Reads exact current or retained accepted source, maps, and provenance.
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
    return Response.json(
      body: await context
          .read<ProposalService>()
          .acceptedBlocks(id, version: version),
    );
  } on NoteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'not_found'},
    );
  } on BlockMapUnavailableException catch (error) {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: {
        'error': error.stale ? 'block_map_stale' : 'block_map_unavailable',
      },
    );
  }
}
