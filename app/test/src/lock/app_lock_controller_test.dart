import 'dart:async';

import 'package:app/src/lock/app_lock_controller.dart';
import 'package:app/src/lock/app_lock_prefs.dart';
import 'package:app/src/lock/biometric_authenticator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeBiometricAuthenticator auth;
  late InMemoryAppLockPrefs prefs;

  AppLockController build() =>
      AppLockController(authenticator: auth, prefs: prefs);

  setUp(() {
    auth = FakeBiometricAuthenticator();
    prefs = InMemoryAppLockPrefs();
  });

  group('load', () {
    test('starts unlocked when the lock is off', () async {
      final c = build();
      await c.load();
      expect(c.loaded, isTrue);
      expect(c.enabled, isFalse);
      expect(c.locked, isFalse);
    });

    test('starts locked when the lock was left on', () async {
      prefs = InMemoryAppLockPrefs(enabled: true);
      final c = build();
      await c.load();
      expect(c.enabled, isTrue);
      expect(c.locked, isTrue);
    });

    test(
      'a saved lock is dropped when the device no longer supports it',
      () async {
        prefs = InMemoryAppLockPrefs(enabled: true);
        auth.capability = LockCapability.unsupported;
        final c = build();
        await c.load();
        expect(c.supported, isFalse);
        expect(c.enabled, isFalse);
        expect(c.locked, isFalse);
        expect(await prefs.readEnabled(), isFalse);
      },
    );

    test('exposes the biometric kind for labels', () async {
      auth.capability = const LockCapability(
        supported: true,
        kind: BiometricKind.fingerprint,
      );
      final c = build();
      await c.load();
      expect(c.kind, BiometricKind.fingerprint);
    });
  });

  group('setEnabled', () {
    test('turning on requires a successful prompt and persists', () async {
      final c = build();
      await c.load();
      expect(await c.setEnabled(true), isTrue);
      expect(c.enabled, isTrue);
      expect(c.locked, isFalse, reason: 'the user just proved presence');
      expect(await prefs.readEnabled(), isTrue);
    });

    test('a failed prompt leaves the lock off', () async {
      auth.result = false;
      final c = build();
      await c.load();
      expect(await c.setEnabled(true), isFalse);
      expect(c.enabled, isFalse);
      expect(await prefs.readEnabled(), isFalse);
    });

    test('turning off also requires a successful prompt', () async {
      prefs = InMemoryAppLockPrefs(enabled: true);
      final c = build();
      await c.load();
      await c.unlock();
      auth.result = false;
      expect(await c.setEnabled(false), isFalse);
      expect(c.enabled, isTrue);

      auth.result = true;
      expect(await c.setEnabled(false), isTrue);
      expect(c.enabled, isFalse);
      expect(await prefs.readEnabled(), isFalse);
    });

    test('is refused on an unsupported device without prompting', () async {
      auth.capability = LockCapability.unsupported;
      final c = build();
      await c.load();
      expect(await c.setEnabled(true), isFalse);
      expect(auth.authenticateCalls, 0);
    });
  });

  group('lock and unlock', () {
    test('lock() only bites when enabled', () async {
      final c = build();
      await c.load();
      c.lock();
      expect(c.locked, isFalse);

      await c.setEnabled(true);
      c.lock();
      expect(c.locked, isTrue);
    });

    test(
      'unlock() clears the lock on success and keeps it on failure',
      () async {
        prefs = InMemoryAppLockPrefs(enabled: true);
        final c = build();
        await c.load();

        auth.result = false;
        expect(await c.unlock(), isFalse);
        expect(c.locked, isTrue);

        auth.result = true;
        expect(await c.unlock(), isTrue);
        expect(c.locked, isFalse);
      },
    );

    test('lock() is ignored while a prompt is on screen', () async {
      final c = build();
      await c.load();
      final release = Completer<void>();
      auth.gate = release.future;

      final pending = c.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.authenticating, isTrue);
      c.lock();
      release.complete();
      await pending;

      expect(c.locked, isFalse);
    });

    test('concurrent unlock() calls share one prompt', () async {
      prefs = InMemoryAppLockPrefs(enabled: true);
      final c = build();
      await c.load();
      final release = Completer<void>();
      auth.gate = release.future;

      final a = c.unlock();
      final b = c.unlock();
      release.complete();
      await Future.wait([a, b]);

      expect(auth.authenticateCalls, 1);
    });
  });

  test('disable() drops the lock without prompting', () async {
    prefs = InMemoryAppLockPrefs(enabled: true);
    final c = build();
    await c.load();
    await c.disable();
    expect(c.enabled, isFalse);
    expect(c.locked, isFalse);
    expect(await prefs.readEnabled(), isFalse);
    expect(auth.authenticateCalls, 0);
  });

  test('disable() clears the stored setting even before load()', () async {
    prefs = InMemoryAppLockPrefs(enabled: true);
    final c = build();
    await c.disable();
    expect(await prefs.readEnabled(), isFalse);
  });

  group('disable() racing load()', () {
    test('a slow load() does not bring the lock back', () async {
      final read = Completer<bool>();
      final slow = _SlowReadPrefs(read.future);
      final c = AppLockController(authenticator: auth, prefs: slow);

      final loading = c.load();
      await Future<void>.delayed(Duration.zero);
      await c.disable();
      read.complete(true); // the value read before disable() cleared it
      await loading;

      expect(c.loaded, isTrue);
      expect(c.enabled, isFalse);
      expect(c.locked, isFalse);
    });
  });

  group('disable() and persistence errors', () {
    test('a load() that fails after disable() does not re-lock', () async {
      final read = Completer<bool>();
      final c = AppLockController(
        authenticator: auth,
        prefs: _SlowReadPrefs(read.future),
      );

      final loading = c.load();
      await Future<void>.delayed(Duration.zero);
      await c.disable();
      read.completeError(StateError('storage unavailable'));
      await loading;

      expect(c.loaded, isTrue);
      expect(c.locked, isFalse);
    });

    test('disable() unlocks even when the write fails', () async {
      final c = AppLockController(
        authenticator: auth,
        prefs: _FailingWritePrefs(enabled: true),
      );
      await c.load();
      expect(c.locked, isTrue);

      await expectLater(c.disable(), throwsA(isA<StateError>()));

      expect(c.enabled, isFalse);
      expect(c.locked, isFalse);
    });

    test(
      'a failed cleanup write does not lock an unsupported device',
      () async {
        auth.capability = LockCapability.unsupported;
        final c = AppLockController(
          authenticator: auth,
          prefs: _FailingWritePrefs(enabled: true),
        );
        await c.load();

        expect(c.enabled, isFalse);
        expect(c.locked, isFalse);
      },
    );
  });

  group('background during a prompt', () {
    test('cancelling the switch-off prompt still locks the app', () async {
      prefs = InMemoryAppLockPrefs(enabled: true);
      final c = build();
      await c.load();
      await c.unlock();
      final release = Completer<void>();
      auth
        ..gate = release.future
        ..result = false;

      final pending = c.setEnabled(false);
      await Future<void>.delayed(Duration.zero);
      c.lock(); // the app was genuinely backgrounded meanwhile
      release.complete();
      await pending;

      expect(c.enabled, isTrue);
      expect(c.locked, isTrue);
    });

    test('a successful prompt is not undone by a lock during it', () async {
      final c = build();
      await c.load();
      final release = Completer<void>();
      auth.gate = release.future;

      final pending = c.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      c.lock();
      release.complete();
      await pending;

      expect(c.locked, isFalse);
    });
  });

  group('startup failures fail closed', () {
    test('a capability error locks and keeps the stored setting', () async {
      prefs = InMemoryAppLockPrefs(enabled: true);
      auth.capabilityError = StateError('channel hiccup');
      final c = build();
      await c.load();

      expect(c.loaded, isTrue);
      expect(c.locked, isTrue);
      expect(await prefs.readEnabled(), isTrue);
    });

    test('a prefs read error locks', () async {
      final c = AppLockController(authenticator: auth, prefs: _ThrowingPrefs());
      await c.load();
      expect(c.loaded, isTrue);
      expect(c.locked, isTrue);
    });

    test('unlock() retries the load and opens a lock that is off', () async {
      auth.capabilityError = StateError('channel hiccup');
      final c = build();
      await c.load();
      expect(c.locked, isTrue);

      auth.capabilityError = null;
      expect(await c.unlock(), isTrue);
      expect(c.locked, isFalse);
      expect(c.enabled, isFalse);
      expect(auth.authenticateCalls, 0, reason: 'the lock was never on');
    });

    test(
      'unlock() retries the load and prompts for a lock that is on',
      () async {
        prefs = InMemoryAppLockPrefs(enabled: true);
        auth.capabilityError = StateError('channel hiccup');
        final c = build();
        await c.load();

        auth.capabilityError = null;
        expect(await c.unlock(), isTrue);
        expect(auth.authenticateCalls, 1);
        expect(c.locked, isFalse);
      },
    );
  });
}

class _SlowReadPrefs implements AppLockPrefs {
  _SlowReadPrefs(this._read);

  final Future<bool> _read;
  bool? written;

  @override
  Future<bool> readEnabled() => _read;

  @override
  Future<void> writeEnabled(bool enabled) async => written = enabled;
}

class _ThrowingPrefs implements AppLockPrefs {
  @override
  Future<bool> readEnabled() async => throw StateError('storage unavailable');

  @override
  Future<void> writeEnabled(bool enabled) async {}
}

class _FailingWritePrefs implements AppLockPrefs {
  _FailingWritePrefs({required this.enabled});

  final bool enabled;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool enabled) async =>
      throw StateError('storage unavailable');
}
