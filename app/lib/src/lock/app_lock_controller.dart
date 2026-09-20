import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_lock_prefs.dart';
import 'biometric_authenticator.dart';

/// Owns the app-lock state: whether the lock is on, whether the app is
/// currently locked, and the biometric prompts that flip either.
///
/// The lock is "on" when the user enabled it in Account; it is "locked"
/// from a cold start and from every trip to the background until the
/// device owner authenticates.
class AppLockController extends ChangeNotifier {
  AppLockController({
    required BiometricAuthenticator authenticator,
    required AppLockPrefs prefs,
  }) : _authenticator = authenticator,
       _prefs = prefs;

  final BiometricAuthenticator _authenticator;
  final AppLockPrefs _prefs;

  bool _loaded = false;
  bool _enabled = false;
  bool _locked = false;
  bool _authenticating = false;
  bool _loadFailed = false;
  bool _lockRequestedDuringPrompt = false;

  /// Bumped by [disable] so a [load] that read the setting before it ran
  /// can't restore the lock afterwards.
  int _disableCount = 0;
  LockCapability _capability = LockCapability.unsupported;
  Future<bool>? _unlockInFlight;

  /// False until [load] resolves; the gate hides content until then so a
  /// lock that is on never flashes the notes first.
  bool get loaded => _loaded;
  bool get enabled => _enabled;
  bool get locked => _locked;
  bool get authenticating => _authenticating;
  bool get supported => _capability.supported;
  BiometricKind get kind => _capability.kind;

  /// Reads the setting and the device's capability. If either read fails
  /// the app stays locked — an unknown state must not open a lock that may
  /// be on — and [unlock] retries the load.
  Future<void> load() async {
    final disablesAtStart = _disableCount;
    try {
      final (capability, stored) = await (
        _authenticator.checkCapability(),
        _prefs.readEnabled(),
      ).wait;
      _capability = capability;
      var enabled = stored;
      if (enabled && !capability.supported) {
        // Biometrics and passcode were removed since the lock was set up;
        // keeping it on would lock the user out for good.
        enabled = false;
        await _prefs.writeEnabled(false);
      }
      if (disablesAtStart == _disableCount) {
        _enabled = enabled;
        _locked = enabled;
      }
      _loadFailed = false;
    } catch (_) {
      _loadFailed = true;
      _locked = true;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Turns the lock on or off after a successful prompt, so a stranger
  /// holding an unlocked phone can't switch it off. Returns whether the
  /// change happened.
  Future<bool> setEnabled(bool value) async {
    if (!_capability.supported || value == _enabled) return false;
    if (!await _prompt(value ? 'Turn on app lock' : 'Turn off app lock')) {
      // The app was backgrounded while the prompt was up and the prompt
      // was not passed: honour the lock that was suppressed meanwhile.
      if (_lockRequestedDuringPrompt) lock();
      return false;
    }
    await _prefs.writeEnabled(value);
    _enabled = value;
    _locked = false;
    notifyListeners();
    return true;
  }

  /// Turns the lock off without a prompt — for when the session is gone
  /// (disconnect, rejected refresh) and the notes the lock protected with
  /// it. Clears the stored setting even if [load] never ran, which is the
  /// case when the session was cleared before the gate mounted.
  Future<void> disable() async {
    _disableCount++;
    await _prefs.writeEnabled(false);
    if (!_enabled && !_locked) return;
    _enabled = false;
    _locked = false;
    notifyListeners();
  }

  /// Locks the app if the lock is on. While a prompt is showing the lock
  /// is only remembered: the system sheet itself sends the app through
  /// lifecycle changes, so re-locking underneath it would loop. A prompt
  /// that then fails still locks (see [setEnabled]).
  void lock() {
    if (_authenticating) {
      _lockRequestedDuringPrompt = true;
      return;
    }
    if (!_enabled || _locked) return;
    _locked = true;
    notifyListeners();
  }

  /// Prompts to unlock. Concurrent calls (cold-start prompt racing a tap
  /// on Unlock) share one prompt.
  Future<bool> unlock() {
    if (!_locked) return Future.value(true);
    return _unlockInFlight ??= _runUnlock();
  }

  Future<bool> _runUnlock() async {
    try {
      if (_loadFailed) {
        await load();
        if (!_locked) return true;
        if (_loadFailed) return false;
      }
      final ok = await _prompt('Unlock robot-notes');
      if (ok) {
        _locked = false;
        notifyListeners();
      }
      return ok;
    } finally {
      _unlockInFlight = null;
    }
  }

  Future<bool> _prompt(String reason) async {
    _lockRequestedDuringPrompt = false;
    _authenticating = true;
    notifyListeners();
    try {
      return await _authenticator.authenticate(reason);
    } finally {
      _authenticating = false;
      notifyListeners();
    }
  }
}
