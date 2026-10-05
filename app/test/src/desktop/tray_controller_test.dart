import 'dart:ui' show Size;

import 'package:app/src/desktop/tray_controller_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class MockTrayIcon extends Mock implements TrayIcon {}

class MockMenu extends Mock implements Menu {}

class MockMenuItem extends Mock implements MenuItem {}

class MockImage extends Mock implements Image {}

class MockWindowManager extends Mock implements WindowManager {}

void main() {
  late MockTrayIcon trayIcon;
  late MockMenu menu;
  late MockMenuItem showItem;
  late MockMenuItem quitItem;
  late MockImage image;
  late MockWindowManager windowManager;
  late void Function(TrayIconEvent) trayListener;
  late void Function(MenuEvent) showListener;
  late void Function(MenuEvent) quitListener;
  late List<(String, MenuItemType)> createdItems;
  late List<String> loadedAssets;

  setUpAll(() {
    registerFallbackValue(
      TrayController(isMacOS: false, windowManager: MockWindowManager()),
    );
    registerFallbackValue((TrayIconEvent _) {});
    registerFallbackValue((MenuEvent _) {});
  });

  setUp(() {
    trayIcon = MockTrayIcon();
    menu = MockMenu();
    showItem = MockMenuItem();
    quitItem = MockMenuItem();
    image = MockImage();
    windowManager = MockWindowManager();
    createdItems = [];
    loadedAssets = [];

    when(() => trayIcon.addListener(any())).thenAnswer((invocation) {
      trayListener =
          invocation.positionalArguments.single as void Function(TrayIconEvent);
      return 1;
    });
    when(() => showItem.addListener(any())).thenAnswer((invocation) {
      showListener =
          invocation.positionalArguments.single as void Function(MenuEvent);
      return 2;
    });
    when(() => quitItem.addListener(any())).thenAnswer((invocation) {
      quitListener =
          invocation.positionalArguments.single as void Function(MenuEvent);
      return 3;
    });
    when(() => trayIcon.removeListener(any())).thenReturn(true);
    when(() => showItem.removeListener(any())).thenReturn(true);
    when(() => quitItem.removeListener(any())).thenReturn(true);
    when(() => trayIcon.setVisible(any())).thenReturn(true);
    when(() => windowManager.ensureInitialized()).thenAnswer((_) async {});
    when(() => windowManager.setPreventClose(any())).thenAnswer((_) async {});
    when(() => windowManager.hide()).thenAnswer((_) async {});
    when(() => windowManager.show()).thenAnswer((_) async {});
    when(() => windowManager.focus()).thenAnswer((_) async {});
  });

  TrayController buildController({
    bool isMacOS = true,
    void Function()? exitApp,
    TrayIcon? Function()? createTrayIcon,
    Menu? Function()? createMenu,
    MenuItem? Function(String, MenuItemType)? createMenuItem,
    Future<Image> Function(String)? loadTrayImage,
  }) {
    return TrayController(
      createTrayIcon: createTrayIcon ?? () => trayIcon,
      createMenu: createMenu ?? () => menu,
      createMenuItem:
          createMenuItem ??
          (label, type) {
            createdItems.add((label, type));
            return label == 'Quit' ? quitItem : showItem;
          },
      loadTrayImage:
          loadTrayImage ??
          (asset) async {
            loadedAssets.add(asset);
            return image;
          },
      windowManager: windowManager,
      isMacOS: isMacOS,
      exitApp: exitApp ?? () {},
    );
  }

  Future<void> expectWindowRestored() async {
    await pumpEventQueue();
    verifyInOrder([() => windowManager.show(), () => windowManager.focus()]);
  }

  void expectCloseUnregistered() {
    verifyNever(() => windowManager.addListener(any()));
    verifyNever(() => windowManager.setPreventClose(any()));
  }

  group('TrayController on macOS', () {
    test('init configures the native tray before preventing close', () async {
      final controller = buildController();
      await controller.init();

      expect(loadedAssets, [trayIconAssetPath]);
      expect(createdItems, [
        ('Show robot-notes', MenuItemType.normal),
        ('Quit', MenuItemType.normal),
      ]);
      verify(() => trayIcon.icon = image).called(1);
      verify(() => trayIcon.isIconTemplate = true).called(1);
      verify(() => trayIcon.iconSize = const Size(18, 18)).called(1);
      verifyInOrder([
        () => menu.addItem(showItem),
        () => menu.addSeparator(),
        () => menu.addItem(quitItem),
        () => trayIcon.setContextMenu(menu),
        () => trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked),
        () => trayIcon.setVisible(true),
        () => windowManager.addListener(controller),
        () => windowManager.setPreventClose(true),
      ]);
      verify(() => windowManager.ensureInitialized()).called(1);
    });

    test('closing and hiding the window keep the app running', () async {
      final controller = buildController();
      await controller.init();

      controller.onWindowClose();
      await controller.hideWindow();

      verify(() => windowManager.hide()).called(2);
    });

    test('native left click restores and focuses the window', () async {
      final controller = buildController();
      await controller.init();

      trayListener(const TrayIconClickedEvent(trayIconId: 1));
      await expectWindowRestored();
    });

    test('right and double clicks do not restore the window', () async {
      final controller = buildController();
      await controller.init();

      trayListener(const TrayIconRightClickedEvent(trayIconId: 1));
      trayListener(const TrayIconDoubleClickedEvent(trayIconId: 1));
      await pumpEventQueue();

      verifyNever(() => windowManager.show());
      verifyNever(() => windowManager.focus());
    });

    test('Show robot-notes menu click restores the window', () async {
      final controller = buildController();
      await controller.init();

      showListener(const MenuItemClickedEvent(itemId: 2));
      await expectWindowRestored();
    });

    test('Quit menu click terminates the app', () async {
      var exited = false;
      final controller = buildController(exitApp: () => exited = true);
      await controller.init();

      quitListener(const MenuItemClickedEvent(itemId: 3));

      expect(exited, isTrue);
    });

    test('submenu events do not trigger menu actions', () async {
      var exited = false;
      final controller = buildController(exitApp: () => exited = true);
      await controller.init();

      showListener(const MenuItemSubmenuOpenedEvent(itemId: 2));
      showListener(const MenuItemSubmenuClosedEvent(itemId: 2));
      quitListener(const MenuItemSubmenuOpenedEvent(itemId: 3));
      quitListener(const MenuItemSubmenuClosedEvent(itemId: 3));
      await pumpEventQueue();

      expect(exited, isFalse);
      verifyNever(() => windowManager.show());
      verifyNever(() => windowManager.focus());
    });

    test('failed tray creation does not prevent closing', () async {
      final controller = buildController(createTrayIcon: () => null);

      await expectLater(controller.init(), throwsStateError);

      expectCloseUnregistered();
      verifyNever(() => trayIcon.dispose());
    });

    test('failed menu creation releases created native resources', () async {
      final controller = buildController(createMenu: () => null);

      await expectLater(controller.init(), throwsStateError);

      expectCloseUnregistered();
      verify(() => trayIcon.dispose()).called(1);
    });

    test('failed menu item creation releases the menu and tray', () async {
      final controller = buildController(createMenuItem: (_, _) => null);

      await expectLater(controller.init(), throwsStateError);

      expectCloseUnregistered();
      verify(() => trayIcon.dispose()).called(1);
      verify(() => menu.dispose()).called(1);
    });

    test('failed image loading does not create native resources', () async {
      final controller = buildController(
        loadTrayImage: (_) => Future.error(StateError('image unavailable')),
      );

      await expectLater(controller.init(), throwsStateError);

      expectCloseUnregistered();
      verifyZeroInteractions(trayIcon);
      verifyNever(() => image.dispose());
    });

    test(
      'failed visibility releases resources without preventing close',
      () async {
        when(() => trayIcon.setVisible(true)).thenReturn(false);
        final controller = buildController();

        await expectLater(controller.init(), throwsStateError);

        expectCloseUnregistered();
        verify(() => trayIcon.dispose()).called(1);
        verify(() => menu.dispose()).called(1);
        verify(() => showItem.dispose()).called(1);
        verify(() => quitItem.dispose()).called(1);
        verify(() => image.dispose()).called(1);
        verify(() => trayIcon.removeListener(1)).called(1);
        verify(() => showItem.removeListener(2)).called(1);
        verify(() => quitItem.removeListener(3)).called(1);

        controller.dispose();
        verifyNever(() => trayIcon.dispose());
      },
    );

    test(
      'dispose unregisters listeners and releases each resource once',
      () async {
        final controller = buildController();
        await controller.init();

        controller.dispose();
        controller.dispose();

        verify(() => windowManager.removeListener(controller)).called(1);
        verify(() => trayIcon.removeListener(1)).called(1);
        verify(() => showItem.removeListener(2)).called(1);
        verify(() => quitItem.removeListener(3)).called(1);
        verify(() => trayIcon.dispose()).called(1);
        verify(() => menu.dispose()).called(1);
        verify(() => showItem.dispose()).called(1);
        verify(() => quitItem.dispose()).called(1);
        verify(() => image.dispose()).called(1);
      },
    );
  });

  group('TrayController off macOS', () {
    test('init, hideWindow and dispose are no-ops', () async {
      final controller = buildController(
        isMacOS: false,
        createTrayIcon: () => throw StateError('must not create tray'),
      );

      await controller.init();
      await controller.hideWindow();
      controller.dispose();

      expect(createdItems, isEmpty);
      expect(loadedAssets, isEmpty);
      verifyZeroInteractions(windowManager);
      verifyZeroInteractions(trayIcon);
      verifyZeroInteractions(menu);
    });
  });
}
