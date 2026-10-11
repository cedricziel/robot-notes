import 'package:meta/meta.dart';
import 'package:server/src/oauth/metadata.dart';

/// Scope granting `list_notes`, `get_note`, and `search_notes`.
const String kScopeNotesRead = 'notes:read';

/// Scope granting `create_note`, `update_note`, `append_to_note`, and
/// `delete_note`.
const String kScopeNotesWrite = 'notes:write';

/// Identity and authorization context for one `/mcp` call.
///
/// Built by the `/mcp` auth middleware (PR 5) from whichever credential
/// authenticated the request: the static API key, which always carries
/// both scopes, or an OAuth access token, which carries whatever scopes
/// were granted at consent. Tools read this instead of the header-derived
/// `Actor` the HTTP routes use, so a stolen `X-Actor` header cannot
/// impersonate an OAuth-authenticated agent.
@immutable
class McpPrincipal {
  /// Creates a principal with an explicit actor, scope set, and source.
  const McpPrincipal({
    required this.actor,
    required this.scopes,
    required this.isStaticKey,
    this.vaultIds = const {'default'},
    this.principalId,
    this.agentOrigin = false,
  });

  /// Convenience constructor for the static API key, which is the root
  /// credential everywhere else in the API and so always holds both
  /// scopes, regardless of any caller-supplied header.
  const McpPrincipal.staticKey(this.actor, {this.agentOrigin = false})
      : scopes = const {kScopeNotesRead, kScopeNotesWrite},
        principalId = 'operator',
        isStaticKey = true,
        vaultIds = const {};

  /// Actor name attributed to this call's writes: the `X-Actor` header for
  /// the static key, or the actor name captured at OAuth consent.
  final String actor;

  /// Restrictive transport origin; never grants scopes or changes identity.
  final bool agentOrigin;

  /// Trusted credential identity, independent of attribution.
  final String? principalId;

  /// Whether this credential permits a capability.
  bool hasScope(String scope) => isStaticKey || scopes.contains(scope);

  /// Applies explicit vault grants, including vault management.
  bool canAccessVault(String id) =>
      isStaticKey ||
      scopes.contains(kScopeVaultsManage) ||
      vaultIds.contains(id);

  /// Allowed vault IDs; static keys have access to all vaults.
  final Set<String> vaultIds;

  /// Scopes granted to this call.
  final Set<String> scopes;

  /// Whether this call was authenticated with the static API key, as
  /// opposed to an OAuth access token.
  final bool isStaticKey;

  /// Whether this principal may call read tools.
  bool get canRead => scopes.contains(kScopeNotesRead);

  /// Whether this principal may call write tools.
  bool get canWrite => scopes.contains(kScopeNotesWrite);
}
