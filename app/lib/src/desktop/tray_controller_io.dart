import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, exit;

import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const trayIconAssetPath = 'assets/tray/tray_icon.png';

Future<Image> _loadTrayImage(String path) async {
  final data = await rootBundle.load(path);
  final image = Image.fromBase64(
    base64Encode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    ),
  );
  if (image == null) throw StateError('Unable to load tray icon: $path');
  return image;
}

/// Keeps the app running via a macOS menu-bar icon instead of quitting when
/// the main window closes. No-op on every other platform.
class TrayController with WindowListener {
  TrayController({
    TrayIcon? Function()? createTrayIcon,
    Menu? Function()? createMenu,
    MenuItem? Function(String, MenuItemType)? createMenuItem,
    Future<Image> Function(String)? loadTrayImage,
    WindowManager? windowManager,
    bool? isMacOS,
    void Function()? exitApp,
  }) : _createTrayIcon = createTrayIcon ?? TrayIcon.create,
       _createMenu = createMenu ?? Menu.create,
       _createMenuItem = createMenuItem ?? MenuItem.createWithLabelAndType,
       _loadImage = loadTrayImage ?? _loadTrayImage,
       _windowManager = windowManager ?? WindowManager.instance,
       _isMacOS = isMacOS ?? Platform.isMacOS,
       _exitApp = exitApp ?? (() => exit(0));

  final TrayIcon? Function() _createTrayIcon;
  final Menu? Function() _createMenu;
  final MenuItem? Function(String, MenuItemType) _createMenuItem;
  final Future<Image> Function(String) _loadImage;
  final WindowManager _windowManager;
  final bool _isMacOS;
  final void Function() _exitApp;

  // Native wrappers own their handles: retain them for the controller lifetime.
  TrayIcon? _trayIcon;
  Menu? _menu;
  Image? _image;
  final List<MenuItem> _items = [];
  final List<int> _itemListenerIds = [];
  int? _trayListenerId;
  bool _listeningToWindow = false;
  Future<void>? _initialization;

  Future<void> init() {
    if (!_isMacOS) return Future.value();
    return _initialization ??= _init();
  }

  Future<void> _init() async {
    try {
      await _windowManager.ensureInitialized();
      _image = await _loadImage(trayIconAssetPath);
      final tray = _trayIcon =
          _createTrayIcon() ?? (throw StateError('Unable to create tray icon'));
      final menu = _menu =
          _createMenu() ?? (throw StateError('Unable to create tray menu'));
      tray
        ..isIconTemplate = true
        ..iconSize = const Size.square(18)
        ..icon = _image;
      _addMenuItem(menu, 'Show robot-notes', () => unawaited(_restore()));
      menu.addSeparator();
      _addMenuItem(menu, 'Quit', _exitApp);
      tray.setContextMenu(menu);
      tray.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      _trayListenerId = tray.addListener((event) {
        if (event is TrayIconClickedEvent) unawaited(_restore());
      });
      if (!tray.setVisible(true)) {
        throw StateError('Unable to show tray icon');
      }
      // Only intercept close once the tray offers a way back into the app.
      _windowManager.addListener(this);
      _listeningToWindow = true;
      await _windowManager.setPreventClose(true);
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  void _addMenuItem(Menu menu, String label, void Function() onClick) {
    final item = _createMenuItem(label, MenuItemType.normal);
    if (item == null) {
      throw StateError('Unable to create tray menu item: $label');
    }
    _items.add(item);
    _itemListenerIds.add(
      item.addListener((event) {
        if (event is MenuItemClickedEvent) onClick();
      }),
    );
    menu.addItem(item);
  }

  Future<void> _restore() async {
    await _windowManager.show();
    await _windowManager.focus();
  }

  /// Backs the menu bar's Window › Close Window. No-op off macOS.
  Future<void> hideWindow() async {
    if (!_isMacOS) return;
    await _windowManager.hide();
  }

  @override
  void onWindowClose() {
    unawaited(_windowManager.hide());
  }

  /// Releases native handles and listeners. Safe to call more than once.
  void dispose() {
    if (_listeningToWindow) {
      _windowManager.removeListener(this);
      _listeningToWindow = false;
    }
    final listenerId = _trayListenerId;
    if (listenerId != null) _trayIcon?.removeListener(listenerId);
    _trayListenerId = null;
    for (var i = 0; i < _itemListenerIds.length; i++) {
      _items[i].removeListener(_itemListenerIds[i]);
    }
    _itemListenerIds.clear();
    _trayIcon?.dispose();
    _trayIcon = null;
    _menu?.dispose();
    _menu = null;
    for (final item in _items) {
      item.dispose();
    }
    _items.clear();
    _image?.dispose();
    _image = null;
  }
}
