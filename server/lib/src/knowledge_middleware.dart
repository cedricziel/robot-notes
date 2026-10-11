import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/rest_principal.dart';

/// Carries only the server-recorded identity into awaited service calls.
Middleware knowledgeIdentity() => (handler) => (context) async {
      final authenticated = context.read<RestPrincipal>().knowledgePrincipal;
      final principal = context.request.headers['x-robot-notes-agent']
                  ?.trim()
                  .toLowerCase() ==
              'true'
          ? authenticated.withAgentOrigin()
          : authenticated;
      try {
        return await withKnowledgePrincipal(
          principal,
          () async =>
              handler(context.provide<KnowledgePrincipal>(() => principal)),
        );
      } on KnowledgeAccessDeniedException catch (error) {
        return Response.json(
          statusCode: 403,
          body: {
            'error': 'knowledge_access_denied',
            'action': error.action.name,
          },
        );
      }
    };
