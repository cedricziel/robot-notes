import 'loopback_redirect_result.dart';

/// Web has no loopback-socket equivalent (the app itself IS the browser
/// tab; there is no separate process to bind a local listener for) — web
/// sign-in uses the same-origin reload flow instead (`web_oauth_callback
/// .dart`, `OidcSignInController.startWebSignIn`/
/// `resumeWebSignInIfPending`). This stub exists only so code that is
/// shared across platforms (but only ever calls [bind] on
/// non-web platforms) still compiles for web.
class LoopbackRedirectServer {
  LoopbackRedirectServer._();

  /// Always throws [UnsupportedError] — desktop-only.
  static Future<LoopbackRedirectServer> bind() {
    throw UnsupportedError(
      'LoopbackRedirectServer is not supported on web; use '
      "OidcSignInController's web sign-in flow instead.",
    );
  }

  /// Unreachable — [bind] always throws first.
  int get port => throw UnsupportedError('not supported on web');

  /// Unreachable — [bind] always throws first.
  String get redirectUri => throw UnsupportedError('not supported on web');

  /// Unreachable — [bind] always throws first.
  Future<LoopbackRedirectResult> waitForCallback() =>
      throw UnsupportedError('not supported on web');

  /// Unreachable — [bind] always throws first.
  Future<void> close() => throw UnsupportedError('not supported on web');
}
