import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/bounded_body.dart';
import 'package:server/src/evidence_store.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';

/// Applies collection policy to immutable capture, reads, and explicit purge.
Future<Response> onRequest(RequestContext context, String id) async {
  final store = context.read<EvidenceStore>();
  final authorization = context.read<NoteAuthorizationService>();
  final principal = currentKnowledgePrincipal;
  final target = KnowledgeTarget.evidenceArchive();
  switch (context.request.method) {
    case HttpMethod.get:
      authorization.require(principal, KnowledgeAction.read, target);
      final evidence = store.read(id);
      return evidence == null
          ? Response.json(statusCode: 404, body: {'error': 'not_found'})
          : Response.json(body: evidence);
    case HttpMethod.delete:
      return authorization.runMutation(
        principal,
        KnowledgeAction.purge,
        target,
        () async {
          store.delete(id);
          return Response(statusCode: HttpStatus.noContent);
        },
      );
    case HttpMethod.put:
      authorization.require(principal, KnowledgeAction.edit, target);
      final bytes =
          await readBoundedBody(context.request, maxBytes: 16 * 1024 * 1024);
      if (bytes == null) {
        return Response.json(
          statusCode: 413,
          body: {'error': 'body_too_large'},
        );
      }
      try {
        final body = jsonDecode(utf8.decode(bytes));
        if (body is! Map<String, dynamic> ||
            body['payload'] is! String ||
            body['retention_days'] is! int ||
            (body['lineage'] != null &&
                body['lineage'] is! Map<String, dynamic>)) {
          throw const FormatException(
            'payload, retention_days, and lineage are invalid',
          );
        }
        final evidence = await authorization.runMutation(
          principal,
          KnowledgeAction.edit,
          target,
          () async => store.put(
            id,
            body['payload'] as String,
            retentionDays: body['retention_days'] as int,
            lineage: (body['lineage'] as Map<String, dynamic>?) ?? const {},
          ),
        );
        return evidence['payload'] == null
            ? Response.json(statusCode: 410, body: {'error': 'evidence_gone'})
            : Response.json(body: evidence);
      } on FormatException catch (error) {
        return Response.json(
          statusCode: 400,
          body: {'error': 'bad_request', 'message': error.message},
        );
      }
    case HttpMethod.head:
    case HttpMethod.options:
    case HttpMethod.patch:
    case HttpMethod.post:
      return Response.json(
        statusCode: 405,
        body: {'error': 'method_not_allowed'},
      );
  }
}
