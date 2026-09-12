import 'package:server/src/public_url.dart';
import 'package:shared/shared.dart';

/// OAuth scopes the server grants: read-only and read/write note access.
const List<String> kOAuthScopes = ['notes:read', 'notes:write'];

/// Builds the RFC 9728 protected-resource metadata document for the given
/// public [base] URL. Identical for `/.well-known/oauth-protected-resource`
/// and its `/mcp` variant.
Map<String, Object?> protectedResourceMetadata(String base) => {
      'resource': mcpResourceUrl(base),
      'authorization_servers': [base],
      'bearer_methods_supported': ['header'],
      'scopes_supported': kOAuthScopes,
      'resource_name': 'robot-notes',
    };

/// Builds the RFC 8414 authorization-server metadata document for the
/// given public [base] URL. Includes `robotnotes_oidc_login_supported:
/// true` when [oidcConfigured] is set; the field is omitted otherwise.
Map<String, Object?> authorizationServerMetadata(
  String base, {
  bool oidcConfigured = false,
}) =>
    {
      'issuer': base,
      'authorization_endpoint': '$base${Routes.oauthAuthorize}',
      'token_endpoint': '$base${Routes.oauthToken}',
      'registration_endpoint': '$base${Routes.oauthRegister}',
      'revocation_endpoint': '$base${Routes.oauthRevoke}',
      'response_types_supported': ['code'],
      'grant_types_supported': ['authorization_code', 'refresh_token'],
      'code_challenge_methods_supported': ['S256'],
      'token_endpoint_auth_methods_supported': [
        'none',
        'client_secret_post',
        'client_secret_basic',
      ],
      'scopes_supported': kOAuthScopes,
      if (oidcConfigured) 'robotnotes_oidc_login_supported': true,
    };
