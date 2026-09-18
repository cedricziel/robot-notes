import 'dart:io' show Platform;

import 'package:window_manager/window_manager.dart';

/// Puts the macOS window into its unified (transparent) title-bar style at
/// startup: the title bar becomes part of the content area — no title
/// text, traffic-light buttons still visible — so [MacWindowChrome] (see
/// `mac_window_chrome.dart`) can draw the app's own chrome up underneath
/// it. No-op on every other platform.
class WindowChromeController {
  WindowChromeController({WindowManager? windowManager, bool? isMacOS})
    : _windowManager = windowManager ?? WindowManager.instance,
      _isMacOS = isMacOS ?? Platform.isMacOS;

  final WindowManager _windowManager;
  final bool _isMacOS;

  Future<void> init() async {
    if (!_isMacOS) return;
    // Also called by TrayController.init(); window_manager's
    // ensureInitialized is idempotent, so running it from both is fine.
    await _windowManager.ensureInitialized();
    await _windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: true,
    );
  }
}

/// Starts a native window drag from the current gesture — backs
/// [MacWindowChrome]'s drag strip's pan handler. [windowManager] is
/// injectable for tests; production callers omit it and hit the real
/// platform channel via [WindowManager.instance].
Future<void> startWindowDrag({WindowManager? windowManager}) =>
    (windowManager ?? WindowManager.instance).startDragging();

/// Toggles the window between maximized (zoomed) and its previous size —
/// backs the drag strip's double-click-to-zoom. [windowManager] is
/// injectable for tests.
Future<void> toggleWindowZoom({WindowManager? windowManager}) async {
  final manager = windowManager ?? WindowManager.instance;
  if (await manager.isMaximized()) {
    await manager.unmaximize();
  } else {
    await manager.maximize();
  }
}
