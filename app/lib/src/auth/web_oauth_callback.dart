import 'package:meta/meta.dart';

/// The `code`/`state` (success) or `error` (failure) query parameters
/// found on the current page URL after a same-origin OIDC redirect back
/// to the web app.
@immutable
class WebOAuthCallback {
  /// Creates a result from the page URL's query parameters.
  const WebOAuthCallback({this.code, this.state, this.error});

  /// The authorization code, present on success.
  final String? code;

  /// The `state` value, present on both success and failure.
  final String? state;

  /// The OAuth `error` code, present when the provider reports a
  /// failure instead of a code.
  final String? error;
}

/// Checks [uri] (the app's current URL — `Uri.base` on web) for OAuth
/// callback query parameters, returning `null` when none are present
/// (the normal case: a fresh load with no pending login).
WebOAuthCallback? extractWebOAuthCallback(Uri uri) {
  final params = uri.queryParameters;
  if (!params.containsKey('code') &&
      !params.containsKey('state') &&
      !params.containsKey('error')) {
    return null;
  }
  return WebOAuthCallback(
    code: params['code'],
    state: params['state'],
    error: params['error'],
  );
}
