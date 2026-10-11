import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';

/// Resolves capabilities for a prospective note without creating accepted data.
Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final target =
      KnowledgeTarget.folder(context.request.uri.queryParameters['path'] ?? '');
  final authorization = context.read<NoteAuthorizationService>();
  return Response.json(
    body: (authorization
          ..require(currentKnowledgePrincipal, KnowledgeAction.read, target))
        .permissions(currentKnowledgePrincipal, target),
  );
}
