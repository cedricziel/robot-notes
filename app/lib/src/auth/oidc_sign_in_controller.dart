import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../config/config_store.dart';
import 'loopback_redirect.dart';
import 'oauth_client.dart';
import 'web_oauth_callback.dart';

/// Sealed state machine for an in-progress or completed OIDC sign-in.
sealed class OidcSignInState {
  const OidcSignInState();
}

/// Nothing is happening — the initial state, and the state after a
/// [OidcSignInController.resumeWebSignInIfPending] call that found no
/// pending login to resume.
class OidcSignInIdle extends OidcSignInState {
  const OidcSignInIdle();
}

/// A sign-in is in progress (waiting on the browser/provider).
class OidcSignInInProgress extends OidcSignInState {
  const OidcSignInInProgress();
}

/// The attempt failed. [message] is safe to show the user.
class OidcSignInFailed extends OidcSignInState {
  const OidcSignInFailed(this.message);
  final String message;
}

/// The attempt succeeded and [config] is ready to persist/use.
class OidcSignInSuccess extends OidcSignInState {
  const OidcSignInSuccess(this.config);
  final AppConfig config;
}

/// Opens a URI for the user to interact with. On desktop this SHOULD open
/// the system browser (an external application); on web it SHOULD
/// navigate the current tab (`_self`) rather than opening a popup, so the
/// reload-based flow in [OidcSignInController.resumeWebSignInIfPending]
/// sees the callback on the same tab.
typedef LaunchUri = Future<void> Function(Uri uri);

/// Drives the app's own OAuth 2.1 + PKCE sign-in against a robot-notes
/// server's OIDC-backed consent flow (see the `oidc-login` capability).
///
/// Desktop ([signInDesktop]) and web ([startWebSignIn] /
/// [resumeWebSignInIfPending]) use different redirect mechanisms — a
/// loopback listener versus a same-origin reload — but both end by
/// exchanging a code at `POST /oauth/token` and persisting the resulting
/// [AppConfig] via [store].
class OidcSignInController extends ValueNotifier<OidcSignInState> {
  /// Creates a controller. [launchUri] is injected so tests never open a
  /// real browser/tab.
  OidcSignInController({
    required ConfigStore store,
    http.Client Function() clientFactory = http.Client.new,
    required this.launchUri,
  }) : _store = store,
       _clientFactory = clientFactory,
       _oauthClient = OAuthClient(store: store, clientFactory: clientFactory),
       super(const OidcSignInIdle());

  final ConfigStore _store;
  final http.Client Function() _clientFactory;
  final OAuthClient _oauthClient;

  /// Opens the authorize URL for the user.
  final LaunchUri launchUri;

  /// Runs the desktop sign-in flow: registers (if needed), opens the
  /// authorize URL in the system browser, waits on a loopback listener
  /// for the redirect, and exchanges the resulting code.
  Future<void> signInDesktop(String baseUrl) async {
    value = const OidcSignInInProgress();
    LoopbackRedirectServer? loopback;
    try {
      loopback = await LoopbackRedirectServer.bind();
      // Captured once: `waitForCallback` (via `Stream.first`) closes the
      // underlying server as soon as it receives the one request it
      // waits for, so `loopback.redirectUri`/`.port` are not safe to
      // re-read afterward.
      final redirectUri = loopback.redirectUri;
      final clientId = await _oauthClient.ensureRegistered(
        baseUrl: baseUrl,
        redirectUri: redirectUri,
      );
      final verifier = generatePkceVerifier();
      final state = generatePkceVerifier();
      final authorizeUri = _oauthClient.buildAuthorizeUri(
        baseUrl: baseUrl,
        clientId: clientId,
        redirectUri: redirectUri,
        codeChallenge: pkceS256Challenge(verifier),
        state: state,
      );

      await launchUri(authorizeUri);
      final result = await loopback.waitForCallback();

      if (result.error != null) {
        value = OidcSignInFailed('Sign-in was cancelled: ${result.error}.');
        return;
      }
      if (result.code == null || result.state != state) {
        value = const OidcSignInFailed(
          'Sign-in response did not match this attempt.',
        );
        return;
      }

      final config = await _exchangeCode(
        baseUrl: baseUrl,
        clientId: clientId,
        code: result.code!,
        codeVerifier: verifier,
        redirectUri: redirectUri,
      );
      await _store.write(config);
      value = OidcSignInSuccess(config);
    } on Object catch (e) {
      value = OidcSignInFailed('Sign-in failed: $e');
    } finally {
      await loopback?.close();
    }
  }

  /// Starts the web sign-in flow: registers (if needed), persists a
  /// [PendingOidcLogin] so the attempt survives the reload the next step
  /// causes, then navigates to the authorize URL via [launchUri].
  Future<void> startWebSignIn({
    required String baseUrl,
    required String redirectUri,
  }) async {
    value = const OidcSignInInProgress();
    try {
      final clientId = await _oauthClient.ensureRegistered(
        baseUrl: baseUrl,
        redirectUri: redirectUri,
      );
      final verifier = generatePkceVerifier();
      final state = generatePkceVerifier();
      await _store.writePendingOidcLogin(
        PendingOidcLogin(
          baseUrl: baseUrl,
          clientId: clientId,
          codeVerifier: verifier,
          state: state,
          redirectUri: redirectUri,
        ),
      );
      final authorizeUri = _oauthClient.buildAuthorizeUri(
        baseUrl: baseUrl,
        clientId: clientId,
        redirectUri: redirectUri,
        codeChallenge: pkceS256Challenge(verifier),
        state: state,
      );
      await launchUri(authorizeUri);
    } on Object catch (e) {
      value = OidcSignInFailed('Sign-in failed: $e');
    }
  }

  /// Checks [pageUri] (the app's current URL — `Uri.base` on web) for an
  /// OIDC callback and, if it matches a pending login started by
  /// [startWebSignIn], completes the exchange. Does nothing (state stays
  /// [OidcSignInIdle]) when [pageUri] has no callback parameters, or none
  /// of them match a pending login — the normal case on every load that
  /// isn't resuming a sign-in.
  Future<void> resumeWebSignInIfPending(Uri pageUri) async {
    final callback = extractWebOAuthCallback(pageUri);
    if (callback == null) return;

    final pending = await _store.readPendingOidcLogin();
    if (pending == null || pending.state != callback.state) return;

    await _store.clearPendingOidcLogin();

    if (callback.error != null) {
      value = OidcSignInFailed('Sign-in was cancelled: ${callback.error}.');
      return;
    }
    if (callback.code == null) {
      value = const OidcSignInFailed(
        'Sign-in response did not match this attempt.',
      );
      return;
    }

    try {
      final config = await _exchangeCode(
        baseUrl: pending.baseUrl,
        clientId: pending.clientId,
        code: callback.code!,
        codeVerifier: pending.codeVerifier,
        redirectUri: pending.redirectUri,
      );
      await _store.write(config);
      value = OidcSignInSuccess(config);
    } on Object catch (e) {
      value = OidcSignInFailed('Sign-in failed: $e');
    }
  }

  Future<AppConfig> _exchangeCode({
    required String baseUrl,
    required String clientId,
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final client = _clientFactory();
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/oauth/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': codeVerifier,
          'client_id': clientId,
        },
      );
      if (response.statusCode != 200) {
        throw _OidcExchangeException(
          'Token exchange failed with HTTP ${response.statusCode}.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const _OidcExchangeException('Token response was not JSON.');
      }
      final accessToken = decoded['access_token'];
      final refreshToken = decoded['refresh_token'];
      if (accessToken is! String || refreshToken is! String) {
        throw const _OidcExchangeException(
          'Token response was missing access_token or refresh_token.',
        );
      }
      final actor = decoded['actor'] is String
          ? decoded['actor'] as String
          : 'unknown';
      return AppConfig(
        baseUrl: baseUrl,
        apiKey: accessToken,
        actor: actor,
        oauthClientId: clientId,
        oauthRefreshToken: refreshToken,
      );
    } finally {
      client.close();
    }
  }
}

@immutable
class _OidcExchangeException implements Exception {
  const _OidcExchangeException(this.message);
  final String message;

  @override
  String toString() => 'OidcExchangeException: $message';
}
