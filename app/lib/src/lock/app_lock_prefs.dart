import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the app lock is on, per device — local only, never sent
/// to the server, same storage as the property panel's collapsed state.
abstract class AppLockPrefs {
  Future<bool> readEnabled();
  Future<void> writeEnabled(bool enabled);
}

/// Production [AppLockPrefs] backed by `shared_preferences`. A storage
/// failure reads as "off": the lock is a convenience guard, and refusing to
/// open the app because prefs are unreadable would be worse.
class SharedPreferencesAppLockPrefs implements AppLockPrefs {
  const SharedPreferencesAppLockPrefs();

  static const _key = 'robot_notes.app_lock.enabled';

  @override
  Future<bool> readEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
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
