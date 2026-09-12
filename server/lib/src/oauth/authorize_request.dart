import 'dart:math';

import 'package:dart_frog/dart_frog.dart';
import 'package:meta/meta.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/code_store.dart';
import 'package:server/src/oauth/metadata.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/oauth_records.dart';
import 'package:server/src/public_url.dart';

/// Byte length for a minted `grant_id`: not a secret (it is stored
/// plaintext alongside codes and tokens to link a family for revocation),
/// but unpredictable so grant families cannot be enumerated.
const int _kGrantIdBytes = 16;

final Random _secureRandom = Random.secure();

/// Outcome of validating an `/oauth/authorize` request. Shared by the
/// GET/POST handlers in `routes/oauth/authorize.dart` and the OIDC
/// login-start route, which re-validates the same parameters (forwarded
/// from the consent page's sign-in link) before starting a login.
@immutable
sealed class AuthorizeValidation {
  const AuthorizeValidation();
}

/// `client_id` is unknown, or `redirect_uri` was not registered for it:
/// the server cannot safely redirect, so it renders an HTML error page.
@immutable
final class AuthorizeClientError extends AuthorizeValidation {
  /// Creates the error with a generic [message].
  const AuthorizeClientError(this.message);

  /// Human-readable error, safe to render directly.
  final String message;
}

/// The client and redirect URI are known; a later check failed. Reported
/// via redirect, per the OAuth authorization-error convention.
@immutable
final class AuthorizeRedirectError extends AuthorizeValidation {
  /// Creates the error, to be reported via redirect to [redirectUri].
  const AuthorizeRedirectError({
    required this.redirectUri,
    required this.error,
    required this.state,
  });

  /// Where to redirect with the error.
  final String redirectUri;

  /// The OAuth `error` query parameter value.
  final String error;

  /// The original request's `state`, echoed back when present.
  final String? state;
}

/// Every check passed.
@immutable
final class AuthorizeValid extends AuthorizeValidation {
  /// Creates the valid result.
  const AuthorizeValid({
    required this.client,
    required this.redirectUri,
    required this.codeChallenge,
    required this.scopes,
    required this.resource,
    required this.state,
  });

  /// The registered client making the request.
  final OAuthClient client;

  /// The registered redirect URI the request will complete to.
  final String redirectUri;

  /// The PKCE `S256` code challenge.
  final String codeChallenge;

  /// Granted scopes (defaults to every scope when the request omits one).
  final Set<String> scopes;

  /// The resolved resource (`<base>/mcp` or `<base>`).
  final String resource;

  /// The original request's opaque `state`, echoed back when present.
  final String? state;
}

/// Validates an `/oauth/authorize` request's [params] (from either the
/// GET query string or a POST form body), per the `oauth-authorization`
/// spec's "Authorization endpoint validates the request" requirement.
Future<AuthorizeValidation> validateAuthorizeRequest(
  RequestContext context,
  Map<String, String> params,
) async {
  final clientId = params['client_id'];
  final redirectUri = params['redirect_uri'];
  if (clientId == null || redirectUri == null) {
    return const AuthorizeClientError(
      'client_id and redirect_uri are required.',
    );
  }

  // Both failures render the same generic message: distinguishing them
  // would let a caller enumerate valid client ids by observing which
  // wording comes back.
  const clientOrRedirectError = AuthorizeClientError(
    'Unknown client_id or unregistered redirect_uri.',
  );
  final client = await context.read<ClientStore>().get(clientId);
  if (client == null) {
    return clientOrRedirectError;
  }
  if (!client.redirectUris.contains(redirectUri)) {
    return clientOrRedirectError;
  }

  final state = params['state'];

  if (params['response_type'] != 'code') {
    return AuthorizeRedirectError(
      redirectUri: redirectUri,
      error: 'unsupported_response_type',
      state: state,
    );
  }

  if (!client.responseTypes.contains('code')) {
    return AuthorizeRedirectError(
      redirectUri: redirectUri,
      error: 'unauthorized_client',
      state: state,
    );
  }

  final codeChallenge = params['code_challenge'];
  if (codeChallenge == null ||
      codeChallenge.isEmpty ||
      params['code_challenge_method'] != 'S256') {
    return AuthorizeRedirectError(
      redirectUri: redirectUri,
      error: 'invalid_request',
      state: state,
    );
  }

  final scopeParam = params['scope'];
  final requestedScopes = (scopeParam == null || scopeParam.trim().isEmpty)
      ? kOAuthScopes.toSet()
      : scopeParam.split(' ').where((s) => s.isNotEmpty).toSet();
  if (requestedScopes.isEmpty ||
      !requestedScopes.every(kOAuthScopes.contains)) {
    return AuthorizeRedirectError(
      redirectUri: redirectUri,
      error: 'invalid_scope',
      state: state,
    );
  }

  final base = publicBaseUrl(context);
  final mcpResource = mcpResourceUrl(base);
  final resourceParam = params['resource'];
  final String resource;
  if (resourceParam == null) {
    resource = mcpResource;
  } else if (resourceParam == mcpResource || resourceParam == base) {
    resource = resourceParam;
  } else {
    return AuthorizeRedirectError(
      redirectUri: redirectUri,
      error: 'invalid_target',
      state: state,
    );
  }

  return AuthorizeValid(
    client: client,
    redirectUri: redirectUri,
    codeChallenge: codeChallenge,
    scopes: requestedScopes,
    resource: resource,
    state: state,
  );
}

/// Mints an authorization code for [valid], attributed to [actor], and
/// returns the `redirect_uri` location (with `code`, `iss`, and `state`
/// when present) to redirect the user agent to.
///
/// Shared by the `api_key` consent submission and the OIDC callback, so
/// both mint codes identically.
Future<String> mintAuthorizationCodeRedirect(
  RequestContext context, {
  required AuthorizeValid valid,
  required String actor,
}) async {
  final code = await context.read<CodeStore>().mint(
        clientId: valid.client.clientId,
        redirectUri: valid.redirectUri,
        codeChallenge: valid.codeChallenge,
        scopes: valid.scopes,
        resource: valid.resource,
        actor: actor,
        grantId: generateRandomToken(_secureRandom, _kGrantIdBytes),
      );

  final base = publicBaseUrl(context);
  return appendQuery(valid.redirectUri, {
    'code': code,
    'iss': base,
    if (valid.state != null) 'state': valid.state!,
  }).toString();
}

/// Appends [extra] query parameters to [uri].
///
/// Built by hand rather than via `Uri.replace(queryParameters: ...)`: that
/// constructor rebuilds the query from `base.queryParameters`, which
/// collapses a repeated key to its last value and re-encodes with
/// `Uri.encodeQueryComponent` (space -> `+`) instead of the `%20` form
/// expected of a URL fragment appended to an opaque, client-controlled
/// query string. Concatenating the raw query verbatim and appending only
/// the new parameters keeps every existing key (duplicates included) and
/// uses `Uri.encodeComponent` (space -> `%20`) for the ones we add.
Uri appendQuery(String uri, Map<String, String> extra) {
  final base = Uri.parse(uri);
  final added = extra.entries
      .map(
        (e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
      )
      .join('&');
  final query = base.query.isEmpty ? added : '${base.query}&$added';
  return base.replace(query: query);
}
