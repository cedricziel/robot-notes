import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';

/// Exposes effective designation and only this credential's allowed actions.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  try {
    final target = await context.read<NoteWriteService>().knowledgeTarget(id);
    final authorization = context.read<NoteAuthorizationService>();
    return Response.json(
      body: (authorization
            ..require(currentKnowledgePrincipal, KnowledgeAction.read, target))
          .permissions(currentKnowledgePrincipal, target),
    );
  } on NoteNotFoundException {
    return Response.json(statusCode: 404, body: {'error': 'not_found'});
  }
}
