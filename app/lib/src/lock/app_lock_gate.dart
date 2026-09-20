import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart' show isApplePlatform;
import 'app_lock_controller.dart';
import 'biometric_authenticator.dart';

/// What the device's unlock method is called in UI copy: the Apple names
/// where the platform has them, a generic name elsewhere.
String lockMethodName(BiometricKind kind, TargetPlatform platform) {
  final apple = isApplePlatform(platform);
  return switch (kind) {
    BiometricKind.face => apple ? 'Face ID' : 'face unlock',
    BiometricKind.fingerprint => apple ? 'Touch ID' : 'fingerprint',
    BiometricKind.other => 'your device passcode',
  };
}

/// Makes the [AppLockController] reachable from the Account surface.
class AppLockScope extends InheritedNotifier<AppLockController> {
  const AppLockScope({
    required AppLockController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  /// `null` where no lock is wired in (tests, web), so callers can simply
  /// omit the setting.
  static AppLockController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLockScope>()?.notifier;
}

/// Hides [child] behind [AppLockScreen] while the app is locked, and locks
/// it whenever the app leaves the foreground.
///
/// [child] stays mounted underneath — hidden, unfocusable, and out of the
/// accessibility tree — so unlocking returns to exactly where the user was
/// and the realtime connection is not torn down.
class AppLockGate extends StatefulWidget {
  const AppLockGate({required this.controller, required this.child, super.key});

  final AppLockController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _resumed = true;

  AppLockController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!_controller.loaded) {
      unawaited(_controller.load().then((_) => _promptIfLocked()));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _promptIfLocked() {
    if (mounted && _controller.locked) unawaited(_controller.unlock());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed != _resumed) setState(() => _resumed = resumed);
    switch (state) {
      // `hidden` rather than `inactive`: the Face ID / fingerprint sheet
      // itself pushes the app to `inactive`, which must not re-lock it.
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _controller.lock();
      case AppLifecycleState.resumed:
        _promptIfLocked();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// On phones the OS snapshots the window for the app switcher while the
  /// app is merely `inactive`, before it is `hidden`. Cover the content then
  /// so the snapshot shows the lock screen rather than notes. Desktop skips
  /// this: losing window focus there is not leaving the screen.
  bool get _coverForSnapshot =>
      _controller.enabled &&
      !_resumed &&
      !_controller.authenticating &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        // Until the setting is known the child is already mounted but
        // hidden, so the session starts connecting while the check runs
        // and a lock that is on never flashes the notes.
        final hidden =
            !_controller.loaded || _controller.locked || _coverForSnapshot;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            Offstage(
              offstage: hidden,
              child: ExcludeFocus(excluding: hidden, child: widget.child),
            ),
            if (hidden && _controller.loaded)
              Positioned.fill(child: AppLockScreen(controller: _controller)),
          ],
        );
      },
    );
  }
}

/// Full-screen "locked" surface with a manual retry, shown when the
/// automatic prompt was cancelled or failed.
class AppLockScreen extends StatelessWidget {
  const AppLockScreen({required this.controller, super.key});

  final AppLockController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final method = lockMethodName(controller.kind, theme.platform);
    return Scaffold(
      key: const Key('lock.screen'),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('robot-notes is locked', style: theme.textTheme.titleLarge),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('lock.unlock'),
              onPressed: controller.authenticating
                  ? null
                  : () => unawaited(controller.unlock()),
              child: Text('Unlock with $method'),
            ),
          ],
        ),
      ),
    );
  }
}
