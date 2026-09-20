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
}
