import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_config.dart';

/// Persistence boundary for [AppConfig].
///
/// The setup screen writes through this interface once validation passes;
/// the rest of the app reads from it on boot. Tests substitute an
/// in-memory implementation; production uses [SecureConfigStore].
abstract class ConfigStore {
  Future<AppConfig?> read();
  Future<void> write(AppConfig config);
  Future<void> clear();
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

  final FlutterSecureStorage _storage;

  @override
  Future<AppConfig?> read() async {
    final baseUrl = await _storage.read(key: _keyBaseUrl);
    final apiKey = await _storage.read(key: _keyApiKey);
    final actor = await _storage.read(key: _keyActor);
    if (baseUrl == null || apiKey == null || actor == null) {
      return null;
    }
    return AppConfig(baseUrl: baseUrl, apiKey: apiKey, actor: actor);
  }

  @override
  Future<void> write(AppConfig config) async {
    await _storage.write(key: _keyBaseUrl, value: config.baseUrl);
    await _storage.write(key: _keyApiKey, value: config.apiKey);
    await _storage.write(key: _keyActor, value: config.actor);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _keyBaseUrl);
    await _storage.delete(key: _keyApiKey);
    await _storage.delete(key: _keyActor);
  }
}

/// In-memory [ConfigStore] for tests. Always start from a known state.
class InMemoryConfigStore implements ConfigStore {
  AppConfig? _config;

  @override
  Future<AppConfig?> read() async => _config;

  @override
  Future<void> write(AppConfig config) async => _config = config;

  @override
  Future<void> clear() async => _config = null;
}
