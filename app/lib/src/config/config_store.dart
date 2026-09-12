import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_config.dart';

/// A web sign-in attempt in progress, persisted immediately before
/// redirecting to the OIDC provider so it survives the page reload that
/// redirect (and the provider's redirect back) causes.
@immutable
class PendingOidcLogin {
  /// Creates a pending login record.
  const PendingOidcLogin({
    required this.baseUrl,
    required this.clientId,
    required this.codeVerifier,
    required this.state,
    required this.redirectUri,
  });

  /// The server this login is against.
  final String baseUrl;

  /// This app's OAuth client id for [baseUrl].
  final String clientId;

  /// This login attempt's own PKCE verifier.
  final String codeVerifier;

  /// The `state` value sent to the provider, matched against the one on
  /// reload.
  final String state;

  /// The same-origin redirect URI used for this attempt.
  final String redirectUri;
}

/// Persistence boundary for [AppConfig].
///
/// The setup screen writes through this interface once validation passes;
/// the rest of the app reads from it on boot. Tests substitute an
/// in-memory implementation; production uses [SecureConfigStore].
abstract class ConfigStore {
  Future<AppConfig?> read();
  Future<void> write(AppConfig config);
  Future<void> clear();

  /// The app's own OAuth client id, registered once via Dynamic Client
  /// Registration against the server at [baseUrl]. Survives [clear] — it
  /// identifies this app installation to that server, not the signed-in
  /// user, so signing out should not force re-registration on the next
  /// sign-in. Returns `null` when nothing is cached for [baseUrl]
  /// (including when a different server's id is cached).
  Future<String?> readRegisteredOAuthClientId(String baseUrl);

  /// Persists the app's registered OAuth client id for [baseUrl].
  Future<void> writeRegisteredOAuthClientId(String baseUrl, String clientId);

  /// The in-progress web sign-in attempt, or `null` if none.
  Future<PendingOidcLogin?> readPendingOidcLogin();

  /// Persists [login] before redirecting to the provider.
  Future<void> writePendingOidcLogin(PendingOidcLogin login);

  /// Clears the pending login once it has been consumed (or abandoned).
  Future<void> clearPendingOidcLogin();
}

/// [ConfigStore] backed by `flutter_secure_storage`.
///
/// On Apple platforms this uses the Keychain, on Android the Keystore /
/// EncryptedSharedPreferences, on desktop a libsecret/wincred wrapper, and
/// on web localStorage with a generated AES key. The API key never lands
/// in plaintext on disk on any first-class platform.
class SecureConfigStore implements ConfigStore {
  SecureConfigStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _keyBaseUrl = 'robot_notes.base_url';
  static const _keyApiKey = 'robot_notes.api_key';
  static const _keyActor = 'robot_notes.actor';
  static const _keyOauthClientId = 'robot_notes.oauth_client_id';
  static const _keyOauthRefreshToken = 'robot_notes.oauth_refresh_token';
  static const _keyRegisteredOauthClientId =
      'robot_notes.registered_oauth_client_id';
  static const _keyPendingLoginBaseUrl = 'robot_notes.pending_login.base_url';
  static const _keyPendingLoginClientId = 'robot_notes.pending_login.client_id';
  static const _keyPendingLoginVerifier = 'robot_notes.pending_login.verifier';
  static const _keyPendingLoginState = 'robot_notes.pending_login.state';
  static const _keyPendingLoginRedirectUri =
      'robot_notes.pending_login.redirect_uri';

  final FlutterSecureStorage _storage;

  @override
  Future<AppConfig?> read() async {
    final baseUrl = await _storage.read(key: _keyBaseUrl);
    final apiKey = await _storage.read(key: _keyApiKey);
    final actor = await _storage.read(key: _keyActor);
    if (baseUrl == null || apiKey == null || actor == null) {
      return null;
    }
    return AppConfig(
      baseUrl: baseUrl,
      apiKey: apiKey,
      actor: actor,
      oauthClientId: await _storage.read(key: _keyOauthClientId),
      oauthRefreshToken: await _storage.read(key: _keyOauthRefreshToken),
    );
  }

  @override
  Future<void> write(AppConfig config) async {
    await _storage.write(key: _keyBaseUrl, value: config.baseUrl);
    await _storage.write(key: _keyApiKey, value: config.apiKey);
    await _storage.write(key: _keyActor, value: config.actor);
    if (config.oauthClientId != null) {
      await _storage.write(key: _keyOauthClientId, value: config.oauthClientId);
    } else {
      await _storage.delete(key: _keyOauthClientId);
    }
    if (config.oauthRefreshToken != null) {
      await _storage.write(
        key: _keyOauthRefreshToken,
        value: config.oauthRefreshToken,
      );
    } else {
      await _storage.delete(key: _keyOauthRefreshToken);
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _keyBaseUrl);
    await _storage.delete(key: _keyApiKey);
    await _storage.delete(key: _keyActor);
    await _storage.delete(key: _keyOauthClientId);
    await _storage.delete(key: _keyOauthRefreshToken);
  }

  @override
  Future<String?> readRegisteredOAuthClientId(String baseUrl) async {
    final raw = await _storage.read(key: _keyRegisteredOauthClientId);
    if (raw == null) return null;
    final separator = raw.indexOf('|');
    if (separator < 0) return null;
    final storedBaseUrl = raw.substring(0, separator);
    if (storedBaseUrl != baseUrl) return null;
    return raw.substring(separator + 1);
  }

  @override
  Future<void> writeRegisteredOAuthClientId(String baseUrl, String clientId) =>
      _storage.write(
        key: _keyRegisteredOauthClientId,
        value: '$baseUrl|$clientId',
      );

  @override
  Future<PendingOidcLogin?> readPendingOidcLogin() async {
    final baseUrl = await _storage.read(key: _keyPendingLoginBaseUrl);
    final clientId = await _storage.read(key: _keyPendingLoginClientId);
    final verifier = await _storage.read(key: _keyPendingLoginVerifier);
    final state = await _storage.read(key: _keyPendingLoginState);
    final redirectUri = await _storage.read(key: _keyPendingLoginRedirectUri);
    if (baseUrl == null ||
        clientId == null ||
        verifier == null ||
        state == null ||
        redirectUri == null) {
      return null;
    }
    return PendingOidcLogin(
      baseUrl: baseUrl,
      clientId: clientId,
      codeVerifier: verifier,
      state: state,
      redirectUri: redirectUri,
    );
  }

  @override
  Future<void> writePendingOidcLogin(PendingOidcLogin login) async {
    await _storage.write(key: _keyPendingLoginBaseUrl, value: login.baseUrl);
    await _storage.write(key: _keyPendingLoginClientId, value: login.clientId);
    await _storage.write(
      key: _keyPendingLoginVerifier,
      value: login.codeVerifier,
    );
    await _storage.write(key: _keyPendingLoginState, value: login.state);
    await _storage.write(
      key: _keyPendingLoginRedirectUri,
      value: login.redirectUri,
    );
  }

  @override
  Future<void> clearPendingOidcLogin() async {
    await _storage.delete(key: _keyPendingLoginBaseUrl);
    await _storage.delete(key: _keyPendingLoginClientId);
    await _storage.delete(key: _keyPendingLoginVerifier);
    await _storage.delete(key: _keyPendingLoginState);
    await _storage.delete(key: _keyPendingLoginRedirectUri);
  }
}

/// In-memory [ConfigStore] for tests. Always start from a known state.
class InMemoryConfigStore implements ConfigStore {
  AppConfig? _config;
  ({String baseUrl, String clientId})? _registeredOAuthClient;

  @override
  Future<AppConfig?> read() async => _config;

  @override
  Future<void> write(AppConfig config) async => _config = config;

  @override
  Future<void> clear() async => _config = null;

  @override
  Future<String?> readRegisteredOAuthClientId(String baseUrl) async {
    final cached = _registeredOAuthClient;
    if (cached == null || cached.baseUrl != baseUrl) return null;
    return cached.clientId;
  }

  @override
  Future<void> writeRegisteredOAuthClientId(
    String baseUrl,
    String clientId,
  ) async => _registeredOAuthClient = (baseUrl: baseUrl, clientId: clientId);

  PendingOidcLogin? _pendingOidcLogin;

  @override
  Future<PendingOidcLogin?> readPendingOidcLogin() async => _pendingOidcLogin;

  @override
  Future<void> writePendingOidcLogin(PendingOidcLogin login) async =>
      _pendingOidcLogin = login;

  @override
  Future<void> clearPendingOidcLogin() async => _pendingOidcLogin = null;
}
