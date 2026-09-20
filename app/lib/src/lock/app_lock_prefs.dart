import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the app lock is on, per device — local only, never sent
/// to the server, same storage as the property panel's collapsed state.
abstract class AppLockPrefs {
  Future<bool> readEnabled();
  Future<void> writeEnabled(bool enabled);
}

/// Production [AppLockPrefs] backed by `shared_preferences`. Errors
/// propagate: an unreadable setting must not be read as "off", or a
/// transient storage failure would open a locked app.
class SharedPreferencesAppLockPrefs implements AppLockPrefs {
  const SharedPreferencesAppLockPrefs();

  static const _key = 'robot_notes.app_lock.enabled';

  @override
  Future<bool> readEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  @override
  Future<void> writeEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}

/// In-memory [AppLockPrefs] for tests.
class InMemoryAppLockPrefs implements AppLockPrefs {
  InMemoryAppLockPrefs({bool enabled = false}) : _enabled = enabled;

  bool _enabled;

  @override
  Future<bool> readEnabled() async => _enabled;

  @override
  Future<void> writeEnabled(bool enabled) async => _enabled = enabled;
}
