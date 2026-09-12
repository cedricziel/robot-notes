import 'dart:io';

import 'loopback_redirect_result.dart';

/// A one-shot HTTP listener on an ephemeral loopback port, used as the
/// `redirect_uri` for desktop sign-in — the same pattern any CLI tool's
/// "opens your browser to log in" flow uses.
///
/// Selected via `loopback_redirect.dart`'s conditional export whenever
/// `dart:io` is available (every platform except web).
class LoopbackRedirectServer {
  LoopbackRedirectServer._(this._server);

  final HttpServer _server;

  /// Binds a fresh listener on an OS-assigned loopback port.
  static Future<LoopbackRedirectServer> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return LoopbackRedirectServer._(server);
  }

  /// The port this listener is bound to.
  ///
  /// Only valid before [waitForCallback] resolves — `Stream.first`
  /// (which [waitForCallback] uses) closes the underlying server as
  /// soon as it delivers the first request, same as calling [close].
  int get port => _server.port;

  /// The `redirect_uri` to register and send in the authorize request.
  /// Same validity caveat as [port].
  String get redirectUri => 'http://127.0.0.1:$port/callback';

  /// Waits for the first request, responds with a plain confirmation
  /// page, and resolves with its query parameters. The listener is
  /// closed as a side effect (see [port]); calling [close] afterward is
  /// still safe (a no-op).
  Future<LoopbackRedirectResult> waitForCallback() async {
    final request = await _server.first;
    final params = request.uri.queryParameters;
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(
        '<!doctype html><html lang="en"><body>'
        '<p>You can close this window and return to Robot Notes.</p>'
        '</body></html>',
      );
    await request.response.close();
    return LoopbackRedirectResult(
      code: params['code'],
      state: params['state'],
      error: params['error'],
    );
  }

  /// Shuts the listener down. Idempotent.
  Future<void> close() => _server.close(force: true);
}
