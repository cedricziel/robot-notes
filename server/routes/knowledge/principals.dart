import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/agent_credentials.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/oauth/token_store.dart';
import 'policies.dart' show resolveKnowledgePolicyTarget;

/// Lists credential identities visible to a policy manager in one vault.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final authorization = context.read<NoteAuthorizationService>();
  final query = context.request.uri.queryParameters;
  final target = await resolveKnowledgePolicyTarget(
    context,
    query.containsKey('kind') ? query : {'kind': 'folder', 'path': ''},
  );
  authorization.require(
    currentKnowledgePrincipal,
    KnowledgeAction.policy,
    target,
  );
  final items = <Map<String, Object?>>[
    {
      'id': 'operator',
      'label': 'Operator',
      'kind': 'operator',
      'capabilities': ['*'],
    },
  ];
  for (final agent in await context.read<AgentCredentialStore>().list()) {
    if (agent.revokedAt != null) continue;
    if (!agent.vaultIds.contains(authorization.vaultId) &&
        !agent.scopes.contains('vaults:manage')) {
      continue;
    }
    items.add({
      'id': 'agent:${agent.id}',
      'label': agent.actor,
      'kind': 'agent',
      'capabilities': agent.scopes.toList()..sort(),
    });
  }
  for (final grant in await context.read<TokenStore>().liveGrants()) {
    if (!grant.vaultIds.contains(authorization.vaultId) &&
        !grant.scopes.contains('vaults:manage')) {
      continue;
    }
    items.add({
      'id': 'oauth:${grant.grantId}',
      'label': grant.actor,
      'kind': 'oauth',
      'capabilities': grant.scopes.toList()..sort(),
    });
  }
  items.sort((a, b) => (a['id']! as String).compareTo(b['id']! as String));
  return Response.json(body: {'items': items});
}
