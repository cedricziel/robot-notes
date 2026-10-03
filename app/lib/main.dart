import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'src/app_router.dart';
import 'src/config/config_store.dart';
import 'src/desktop/app_menu_actions.dart';
import 'src/desktop/app_menu_bar.dart';
import 'src/desktop/mac_window_chrome.dart';
import 'src/desktop/tray_controller.dart';
import 'src/desktop/window_chrome.dart';
import 'src/lock/app_lock_controller.dart';
import 'src/lock/app_lock_prefs.dart';
import 'src/lock/biometric_authenticator.dart';
import 'src/otel/otel_bootstrap.dart';
import 'src/theme/app_theme.dart';
import 'src/url_strategy.dart';

export 'src/app_router.dart' show NoteRoute, blankNoteTitle, createBlankNote;

/// Set only by `fastlane capture_screenshots`'s `--dart-define`, never by a
/// developer build — see [_RobotNotesAppState.build].
const bool _isScreenshotCapture = bool.fromEnvironment('SCREENSHOT_CAPTURE');

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // Web leaves the semantics tree off until the user finds a hidden
  // enable-accessibility control; native platforms turn it on themselves.
  if (kIsWeb) binding.ensureSemantics();
  configureUrlStrategy();
  await initOtel();
  final tray = TrayController();
  unawaited(tray.init());
  unawaited(WindowChromeController().init());
  runApp(RobotNotesApp(onCloseWindow: tray.hideWindow));
}

/// Root widget for the robot-notes Flutter client. Owns the [GoRouter] and
/// the [ConfigHolder] that drives its first-run redirect for the app's
/// entire lifetime, plus the [AppMenuActions] registry behind the macOS
/// menu bar.
class RobotNotesApp extends StatefulWidget {
  const RobotNotesApp({this.onCloseWindow, super.key});

  /// Backs the macOS menu bar's Window › Close Window (⌘W). `null` omits
  /// the item.
  final VoidCallback? onCloseWindow;

  @override
  State<RobotNotesApp> createState() => _RobotNotesAppState();
}

class _RobotNotesAppState extends State<RobotNotesApp> {
  final ConfigStore _store = SecureConfigStore();
  late final ConfigHolder _configHolder = ConfigHolder(_store);
  late final GoRouter _router = buildAppRouter(configHolder: _configHolder);
  final AppMenuActions _menuActions = AppMenuActions();
  final AppLockController _appLock = AppLockController(
    authenticator: LocalAuthBiometricAuthenticator(),
    prefs: const SharedPreferencesAppLockPrefs(),
  );

  // Tracks which server's OTel config is currently loaded so a ConfigHolder
  // notification that doesn't change the base URL (unrelated field edits;
  // duplicate loads) doesn't trigger a redundant fetch.
  String? _otelSyncedBaseUrl;

  @override
  void initState() {
    super.initState();
    _configHolder.addListener(_syncOtel);
    _configHolder.addListener(_dropLockOnDisconnect);
  }

  /// Disconnecting wipes the notes the lock protected, and the setup screen
  /// is not gated — leaving the lock on would only make the next sign-in
  /// start with a biometric prompt for nothing.
  void _dropLockOnDisconnect() {
    if (_configHolder.loaded && _configHolder.config == null) {
      unawaited(_appLock.disable());
    }
  }

  void _syncOtel() {
    final baseUrl = _configHolder.config?.baseUrl;
    if (baseUrl == _otelSyncedBaseUrl) return;
    _otelSyncedBaseUrl = baseUrl;
    unawaited(syncOtelWithConfig(_configHolder.config));
  }

  @override
  void dispose() {
    _configHolder.removeListener(_syncOtel);
    _configHolder.removeListener(_dropLockOnDisconnect);
    _configHolder.dispose();
    _appLock.dispose();
    _router.dispose();
    _menuActions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'robot-notes',
      // Suppressed only for App Store screenshot capture (see
      // app/integration_test/screenshot_test.dart) — a real device debug
      // build should keep the banner as a normal signal it isn't a release
      // build. Profile/release mode (which hides it automatically) isn't
      // buildable for the iOS/iPad Simulators screenshot capture runs on.
      debugShowCheckedModeBanner: !_isScreenshotCapture,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: _router,
      builder: (context, child) => AppMenuBar(
        actions: _menuActions,
        onCloseWindow: widget.onCloseWindow,
        child: AppMenuActionsScope(
          actions: _menuActions,
          child: MacWindowChrome(
            child: AppRouterShell(
              configHolder: _configHolder,
              appLock: _appLock,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
