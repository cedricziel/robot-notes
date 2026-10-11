import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';

/// Resolves an existing note, a folder, or the evidence archive collection.
Future<KnowledgeTarget> resolveKnowledgePolicyTarget(
  RequestContext context,
  Map<String, dynamic> raw,
) async {
  switch (raw['kind']) {
    case 'note':
      if (raw['id'] is! String) throw const FormatException('Note ID required');
      return context
          .read<NoteWriteService>()
          .knowledgeTarget(raw['id'] as String);
    case 'folder':
      if (raw['path'] is! String) {
        throw const FormatException('Folder path required');
      }
      return KnowledgeTarget.folder(raw['path'] as String);
    case 'collection':
      if (raw['name'] != 'evidence_archive') {
        throw const FormatException('Unknown collection');
      }
      return KnowledgeTarget.evidenceArchive();
    default:
      throw const FormatException('Invalid policy target');
  }
}

/// Inspects or conditionally replaces a single server-owned overlay.
Future<Response> onRequest(RequestContext context) async {
  final authorization = context.read<NoteAuthorizationService>();
  final method = context.request.method;
  if (method != HttpMethod.get &&
      method != HttpMethod.put &&
      method != HttpMethod.delete) {
    return Response(statusCode: 405);
  }
  try {
    Map<String, dynamic> targetJson = context.request.uri.queryParameters;
    KnowledgePolicyPatch? patch;
    if (method == HttpMethod.put) {
      final raw = await context.request.json();
      if (raw is! Map<String, dynamic> ||
          raw['target'] is! Map<String, dynamic> ||
          raw['policy'] is! Map<String, dynamic>) {
        throw const FormatException('Invalid policy request');
      }
      targetJson = raw['target'] as Map<String, dynamic>;
      patch =
          KnowledgePolicyPatch.fromJson(raw['policy'] as Map<String, dynamic>);
    }
    final target = await resolveKnowledgePolicyTarget(context, targetJson);
    authorization.require(
      currentKnowledgePrincipal,
      KnowledgeAction.policy,
      target,
    );
    if (method != HttpMethod.get) {
      final match = context.request.headers['if-match'];
      if (match == null) {
        return Response.json(
          statusCode: 428,
          body: {'error': 'policy_version_required'},
        );
      }
      final revision = int.tryParse(match.replaceAll('"', ''));
      if (revision == null || revision < 0) {
        throw const FormatException('Invalid policy revision');
      }
      await authorization.changePolicy(
        currentKnowledgePrincipal,
        target,
        patch,
        ifMatch: revision,
      );
    }
    return Response.json(
      headers: {'etag': '"${authorization.store.revision}"'},
      body: authorization.inspectPolicy(currentKnowledgePrincipal, target),
    );
  } on KnowledgePolicyConflict catch (error) {
    return Response.json(
      statusCode: 409,
      body: {
        'error': 'policy_version_conflict',
        'current_policy_revision': error.currentRevision,
      },
    );
  } on FormatException {
    return Response.json(statusCode: 400, body: {'error': 'bad_request'});
  } on InvalidPathException {
    return Response.json(statusCode: 400, body: {'error': 'bad_request'});
  } on NoteNotFoundException {
    return Response.json(statusCode: 404, body: {'error': 'not_found'});
  }
}
