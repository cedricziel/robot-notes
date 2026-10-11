import 'dart:async';

import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/rest_principal.dart';

final Object _principalZone = Object();

class _PrincipalLease {
  _PrincipalLease(this.principal);
  final KnowledgePrincipal principal;
  bool active = true;
}

/// Missing or expired request context has no authority.
KnowledgePrincipal get currentKnowledgePrincipal {
  final lease = Zone.current[_principalZone];
  return lease is _PrincipalLease && lease.active
      ? lease.principal
      : const KnowledgePrincipal.unidentified();
}

/// Binds one recorded principal to awaited request work, without shared state.
Future<T> withKnowledgePrincipal<T>(
  KnowledgePrincipal principal,
  Future<T> Function() body,
) async {
  final lease = _PrincipalLease(principal);
  try {
    return await runZoned(body, zoneValues: {_principalZone: lease});
  } finally {
    lease.active = false;
  }
}

/// Converts only the identity and grants recorded by REST authentication.
extension RestKnowledgeIdentity on RestPrincipal {
  /// Actor headers and exempt routes cannot supply a credential identity.
  KnowledgePrincipal get knowledgePrincipal {
    if (kind == RestAuthKind.staticKey) {
      return const KnowledgePrincipal.operator();
    }
    final id = principalId;
    if (kind == RestAuthKind.agentCredential &&
        id != null &&
        id.startsWith('agent:')) {
      return KnowledgePrincipal.agent(
        credentialId: id.substring(6),
        scopes: scopes ?? {},
        vaultIds: vaultIds,
      );
    }
    if (kind == RestAuthKind.oauthToken &&
        id != null &&
        id.startsWith('oauth:')) {
      return KnowledgePrincipal.oauth(
        grantId: id.substring(6),
        scopes: scopes ?? {},
        vaultIds: vaultIds,
      );
    }
    return const KnowledgePrincipal.unidentified();
  }
}

/// Converts only the recorded MCP principal, never caller actor attribution.
extension McpKnowledgeIdentity on McpPrincipal {
  /// Unknown identity fails closed even when a scope set was supplied.
  KnowledgePrincipal get knowledgePrincipal {
    if (isStaticKey) return const KnowledgePrincipal.operator();
    final id = principalId;
    if (id != null && id.startsWith('agent:')) {
      return KnowledgePrincipal.agent(
        credentialId: id.substring(6),
        scopes: scopes,
        vaultIds: vaultIds,
      );
    }
    if (id != null && id.startsWith('oauth:')) {
      return KnowledgePrincipal.oauth(
        grantId: id.substring(6),
        scopes: scopes,
        vaultIds: vaultIds,
      );
    }
    return const KnowledgePrincipal.unidentified();
  }
}
