import 'package:meta/meta.dart';
import 'package:server/src/oauth/metadata.dart';

/// How a REST/WebSocket request authenticated, as decided by `bearerAuth`
/// (`lib/src/auth_middleware.dart`).
enum RestAuthKind {
  /// The path is exempt from authentication entirely (e.g. `/healthz`).
  exempt,

  /// Authenticated with the operator's static bearer key.
  staticKey,

  /// Authenticated with a scoped OAuth access token issued by this
  /// server's own authorization server for the REST/WS resource.
  oauthToken,
}

/// Always provided by `bearerAuth` on every request that reaches a route
/// handler, so downstream middleware (actor resolution) and handlers can
/// tell how the request authenticated without re-deriving it.
@immutable
class RestPrincipal {
  const RestPrincipal._(
    this.kind, {
    this.actor,
    this.scopes,
    this.vaultIds = const {'default'},
  });

  /// The exempt-path principal.
  const RestPrincipal.exempt() : this._(RestAuthKind.exempt);

  /// The static-key principal.
  const RestPrincipal.staticKey() : this._(RestAuthKind.staticKey);

  /// The OAuth-token principal, carrying the grant's recorded [actor] and
  /// [scopes].
  const RestPrincipal.oauth({
    required String actor,
    required Set<String> scopes,
    Set<String> vaultIds = const {'default'},
  }) : this._(
          RestAuthKind.oauthToken,
          actor: actor,
          scopes: scopes,
          vaultIds: vaultIds,
        );

  /// Whether this credential can manage all current and future vaults.
  bool get canManageVaults =>
      kind == RestAuthKind.staticKey ||
      (kind == RestAuthKind.oauthToken &&
          (scopes?.contains(kScopeVaultsManage) ?? false));

  /// Whether the grant permits access to a vault.
  bool canAccessVault(String id) => canManageVaults || vaultIds.contains(id);

  /// Vault IDs authorized by the OAuth grant.
  final Set<String> vaultIds;

  /// Which credential authenticated the request.
  final RestAuthKind kind;

  /// The token's recorded actor. Only set when [kind] is
  /// [RestAuthKind.oauthToken].
  final String? actor;

  /// The token's granted scopes. Only set when [kind] is
  /// [RestAuthKind.oauthToken].
  final Set<String>? scopes;
}
