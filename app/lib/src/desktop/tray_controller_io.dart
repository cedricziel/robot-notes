import 'dart:io' show Platform, exit;

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const trayIconAssetPath = 'assets/tray/tray_icon.png';

/// Keeps the app running via a macOS menu-bar icon instead of quitting when
/// the main window closes. No-op on every other platform.
class TrayController with TrayListener, WindowListener {
  TrayController({
    TrayManager? trayManager,
    WindowManager? windowManager,
    bool? isMacOS,
    void Function()? exitApp,
  }) : _trayManager = trayManager ?? TrayManager.instance,
       _windowManager = windowManager ?? WindowManager.instance,
       _isMacOS = isMacOS ?? Platform.isMacOS,
       _exitApp = exitApp ?? (() => exit(0));

  final TrayManager _trayManager;
  final WindowManager _windowManager;
  final bool _isMacOS;
  final void Function() _exitApp;

  Future<void> init() async {
    if (!_isMacOS) return;

    _trayManager.addListener(this);
    _windowManager.addListener(this);

    await _windowManager.ensureInitialized();
    // setPreventClose (window_manager channel) and the tray icon/menu setup
    // (tray_manager channel) touch independent native objects, so they run
    // concurrently; the icon must still be set before the menu that attaches
    // to it.
    await Future.wait([
      _windowManager.setPreventClose(true),
      _trayManager
          .setIcon(trayIconAssetPath, isTemplate: true)
          .then((_) => _trayManager.setContextMenu(_trayMenu())),
    ]);
  }

  Menu _trayMenu() => Menu(
    items: [
      MenuItem(
        key: 'show_window',
        label: 'Show robot-notes',
        onClick: (_) => _restore(),
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit', onClick: (_) => _exitApp()),
    ],
  );

  Future<void> _restore() async {
    await _windowManager.show();
    await _windowManager.focus();
  }

  /// Hides the window the way closing it does (the tray icon keeps the app
  /// alive); backs the menu bar's Window › Close Window. No-op off macOS.
  Future<void> hideWindow() async {
    if (!_isMacOS) return;
    await _windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    _restore();
  }

  @override
  void onWindowClose() {
    _windowManager.hide();
  }
}
