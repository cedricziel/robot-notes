import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:shared/shared.dart';

/// One-line human descriptions shown next to each requested scope on the
/// consent page.
const Map<String, String> _kScopeDescriptions = {
  'notes:read': 'Read notes and run searches across the workspace.',
  'notes:write': 'Create, edit, append to, and delete notes.',
};

/// The authorization parameters the consent form must round-trip to
/// `POST /oauth/authorize` as hidden inputs (design decision D9: the GET
/// step holds no server state).
@immutable
class ConsentPageParams {
  /// Creates the parameter bundle rendered by [renderConsentPage].
  const ConsentPageParams({
    required this.clientId,
    required this.clientName,
    required this.redirectUri,
    required this.responseType,
    required this.codeChallenge,
    required this.codeChallengeMethod,
    required this.scopes,
    this.state,
    this.resource,
  });

  /// The requesting client's id.
  final String clientId;

  /// The requesting client's registered display name.
  final String clientName;

  /// The redirect URI the consent decision will be returned to.
  final String redirectUri;

  /// Always `code` for the supported flow.
  final String responseType;

  /// The PKCE `code_challenge` supplied by the client.
  final String codeChallenge;

  /// Always `S256` for the supported flow.
  final String codeChallengeMethod;

  /// The scopes to be granted, already defaulted when the client omitted
  /// `scope`.
  final Set<String> scopes;

  /// The client's opaque `state`, echoed back verbatim, or `null`.
  final String? state;

  /// The `resource` indicator, when the client supplied one.
  final String? resource;
}

// `attribute` mode escapes `&`, `<`, `>`, and `"` but leaves `/` alone,
// which is what both the hidden-input attribute values and the plain-text
// client name/error banner need here.
const HtmlEscape _esc = HtmlEscape(HtmlEscapeMode.attribute);

/// Renders the OAuth consent form for [params] as a self-contained HTML
/// document: no external resources, no JavaScript, every interpolated
/// value escaped. When [errorMessage] is set (a failed API key check, or
/// a failed OIDC login), an error banner is shown above the form. When
/// [oidcConfigured] is `true`, the identity-proving step is a sign-in
/// link to the OIDC login flow instead of the `api_key` form field.
String renderConsentPage(
  ConsentPageParams params, {
  String? errorMessage,
  bool oidcConfigured = false,
}) {
  final scopeItems = (params.scopes.toList()..sort())
      .map(
        (scope) => '<li><code>${_esc.convert(scope)}</code> — '
            '${_esc.convert(_kScopeDescriptions[scope] ?? scope)}</li>',
      )
      .join();

  final errorBanner = errorMessage == null
      ? ''
      : '<p class="error">${_esc.convert(errorMessage)}</p>';

  final clientName = _esc.convert(params.clientName);

  final identityStep =
      oidcConfigured ? _signInLink(params) : _apiKeyForm(params, clientName);

  return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Authorize $clientName</title>
<style>
  body { font: 14px/1.5 system-ui, sans-serif; max-width: 32rem; margin: 3rem auto; padding: 0 1rem; }
  .error { color: #b00020; }
  label { display: block; margin-top: 1rem; }
  input[type=password], input[type=text] { width: 100%; padding: .4rem; box-sizing: border-box; }
  button, .sign-in { margin-top: 1.5rem; padding: .5rem 1rem; }
</style>
</head>
<body>
<h1>$clientName wants to access robot-notes</h1>
$errorBanner
<p>This will grant:</p>
<ul>$scopeItems</ul>
$identityStep
</body>
</html>
''';
}

String _apiKeyForm(ConsentPageParams params, String clientName) {
  final hiddenFields = [
    _hidden('client_id', params.clientId),
    _hidden('redirect_uri', params.redirectUri),
    _hidden('response_type', params.responseType),
    _hidden('code_challenge', params.codeChallenge),
    _hidden('code_challenge_method', params.codeChallengeMethod),
    _hidden('state', params.state),
    _hidden('scope', (params.scopes.toList()..sort()).join(' ')),
    _hidden('resource', params.resource),
  ].join();

  return '''
<form method="post" action="${Routes.oauthAuthorize}">
$hiddenFields
<label for="api_key">Workspace API key</label>
<input id="api_key" type="password" name="api_key" autocomplete="off" required>
<label for="actor">Acting as</label>
<input id="actor" type="text" name="actor" value="$clientName">
<button type="submit">Authorize</button>
</form>
''';
}

String _signInLink(ConsentPageParams params) {
  final queryParams = <String, String>{
    'client_id': params.clientId,
    'redirect_uri': params.redirectUri,
    'response_type': params.responseType,
    'code_challenge': params.codeChallenge,
    'code_challenge_method': params.codeChallengeMethod,
    'scope': (params.scopes.toList()..sort()).join(' '),
    if (params.resource != null) 'resource': params.resource!,
    if (params.state != null) 'state': params.state!,
  };
  final query = queryParams.entries
      .map(
        (e) => '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
  final href = _esc.convert('${Routes.oauthOidcLogin}?$query');
  return '<p><a class="sign-in" href="$href">Sign in with your identity '
      'provider</a></p>';
}

String _hidden(String name, String? value) => value == null
    ? ''
    : '<input type="hidden" name="$name" value="${_esc.convert(value)}">';
