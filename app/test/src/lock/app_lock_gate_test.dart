import 'dart:async';

import 'package:app/src/lock/app_lock_controller.dart';
import 'package:app/src/lock/app_lock_gate.dart';
import 'package:app/src/lock/app_lock_prefs.dart';
import 'package:app/src/lock/biometric_authenticator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeBiometricAuthenticator auth;

  Future<AppLockController> pump(
    WidgetTester tester, {
    bool enabled = true,
  }) async {
    final controller = AppLockController(
      authenticator: auth,
      prefs: InMemoryAppLockPrefs(enabled: enabled),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppLockGate(
          controller: controller,
          child: const Scaffold(body: Text('secret note')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  setUp(() => auth = FakeBiometricAuthenticator());

  testWidgets('shows nothing until the lock state is known', (tester) async {
    final release = Completer<void>();
    final controller = AppLockController(
      authenticator: _SlowCapability(auth, release.future),
      prefs: InMemoryAppLockPrefs(enabled: true),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppLockGate(
          controller: controller,
          child: const Text('secret note'),
        ),
      ),
    );
    expect(find.text('secret note'), findsNothing);
    expect(find.byKey(const Key('lock.screen')), findsNothing);

    release.complete();
    await tester.pumpAndSettle();
    expect(find.text('secret note'), findsOneWidget);
  });

  testWidgets('shows the content straight away when the lock is off', (
    tester,
  ) async {
    await pump(tester, enabled: false);
    expect(find.text('secret note'), findsOneWidget);
    expect(find.byKey(const Key('lock.screen')), findsNothing);
    expect(auth.authenticateCalls, 0);
  });

  testWidgets('a cold start with the lock on prompts and reveals on success', (
    tester,
  ) async {
    await pump(tester);
    expect(auth.authenticateCalls, 1);
    expect(find.text('secret note'), findsOneWidget);
    expect(find.byKey(const Key('lock.screen')), findsNothing);
  });

  testWidgets('a failed prompt keeps the content hidden until Unlock works', (
    tester,
  ) async {
    auth.result = false;
    await pump(tester);
    expect(find.byKey(const Key('lock.screen')), findsOneWidget);
    expect(find.text('secret note'), findsNothing);

    auth.result = true;
    await tester.tap(find.byKey(const Key('lock.unlock')));
    await tester.pump();
    await tester.pump();
    expect(auth.authenticateCalls, 2);
    expect(find.text('secret note'), findsOneWidget);
  });

  testWidgets('the locked content stays mounted, keeping its state', (
    tester,
  ) async {
    auth.result = false;
    await pump(tester);
    expect(find.text('secret note', skipOffstage: false), findsOneWidget);
  });

  testWidgets('going to the background locks; coming back prompts', (
    tester,
  ) async {
    await pump(tester);
    expect(auth.authenticateCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(find.byKey(const Key('lock.screen')), findsOneWidget);
    expect(find.text('secret note'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(auth.authenticateCalls, 2);
    expect(find.text('secret note'), findsOneWidget);
  });

  testWidgets('a lock that is off ignores the background', (tester) async {
    await pump(tester, enabled: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(find.text('secret note'), findsOneWidget);
  });

  testWidgets('the Unlock button is worded for the device biometric', (
    tester,
  ) async {
    auth
      ..result = false
      ..capability = const LockCapability(
        supported: true,
        kind: BiometricKind.fingerprint,
      );
    await pump(tester);
    expect(find.text('Unlock with fingerprint'), findsOneWidget);
  });

  group('lockMethodName', () {
    test('names Face ID and Touch ID on Apple platforms', () {
      expect(lockMethodName(BiometricKind.face, TargetPlatform.iOS), 'Face ID');
      expect(
        lockMethodName(BiometricKind.fingerprint, TargetPlatform.iOS),
        'Touch ID',
      );
      expect(
        lockMethodName(BiometricKind.fingerprint, TargetPlatform.macOS),
        'Touch ID',
      );
    });

    test('uses generic names elsewhere', () {
      expect(
        lockMethodName(BiometricKind.face, TargetPlatform.android),
        'face unlock',
      );
      expect(
        lockMethodName(BiometricKind.fingerprint, TargetPlatform.android),
        'fingerprint',
      );
      expect(
        lockMethodName(BiometricKind.other, TargetPlatform.iOS),
        'your device passcode',
      );
    });
  });
}

/// Delays the capability check, so the controller stays unloaded.
class _SlowCapability implements BiometricAuthenticator {
  _SlowCapability(this._inner, this._release);

  final BiometricAuthenticator _inner;
  final Future<void> _release;

  @override
  Future<LockCapability> checkCapability() async {
    await _release;
    return _inner.checkCapability();
  }

  @override
  Future<bool> authenticate(String reason) => _inner.authenticate(reason);
}
