import 'package:app/src/desktop/tray_controller_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class MockTrayManager extends Mock implements TrayManager {}

class MockWindowManager extends Mock implements WindowManager {}

void main() {
  late MockTrayManager trayManager;
  late MockWindowManager windowManager;

  setUpAll(() {
    registerFallbackValue(Menu());
  });

  setUp(() {
    trayManager = MockTrayManager();
    windowManager = MockWindowManager();

    when(
      () => trayManager.setIcon(any(), isTemplate: any(named: 'isTemplate')),
    ).thenAnswer((_) async {});
    when(() => trayManager.setContextMenu(any())).thenAnswer((_) async {});
    when(() => windowManager.ensureInitialized()).thenAnswer((_) async {});
    when(() => windowManager.setPreventClose(any())).thenAnswer((_) async {});
    when(() => windowManager.hide()).thenAnswer((_) async {});
    when(() => windowManager.show()).thenAnswer((_) async {});
    when(() => windowManager.focus()).thenAnswer((_) async {});
  });

  TrayController buildController({
    bool isMacOS = true,
    void Function()? exitApp,
  }) {
    return TrayController(
      trayManager: trayManager,
      windowManager: windowManager,
      isMacOS: isMacOS,
      exitApp: exitApp ?? () {},
    );
  }

  Menu capturedMenu() =>
      verify(() => trayManager.setContextMenu(captureAny())).captured.single
          as Menu;

  Future<void> expectWindowRestored() async {
    await pumpEventQueue();
    verify(() => windowManager.show()).called(1);
    verify(() => windowManager.focus()).called(1);
  }

  group('TrayController on macOS', () {
    test(
      'init registers the tray icon, menu, and prevents native close',
      () async {
        final controller = buildController();

        await controller.init();

        verify(() => trayManager.setIcon(any(), isTemplate: true)).called(1);
        verify(() => trayManager.setContextMenu(any())).called(1);
        verify(() => windowManager.ensureInitialized()).called(1);
        verify(() => windowManager.setPreventClose(true)).called(1);
      },
    );

    test('closing the window hides it instead of quitting', () async {
      final controller = buildController();
      await controller.init();

      controller.onWindowClose();

      verify(() => windowManager.hide()).called(1);
    });

    test('clicking the tray icon restores and focuses the window', () async {
      final controller = buildController();
      await controller.init();

      controller.onTrayIconMouseDown();
      await expectWindowRestored();
    });

    test(
      '"Show robot-notes" menu item restores and focuses the window',
      () async {
        final controller = buildController();
        await controller.init();

        final showItem = capturedMenu().getMenuItem('show_window');
        expect(showItem, isNotNull);

        showItem!.onClick?.call(showItem);
        await expectWindowRestored();
      },
    );

    test('"Quit" menu item terminates the app', () async {
      var exited = false;
      final controller = buildController(exitApp: () => exited = true);
      await controller.init();

      final quitItem = capturedMenu().getMenuItem('quit');
      expect(quitItem, isNotNull);

      quitItem!.onClick?.call(quitItem);

      expect(exited, isTrue);
    });
  });

  group('TrayController off macOS', () {
    test('init is a no-op', () async {
      final controller = buildController(isMacOS: false);

      await controller.init();

      verifyNever(
        () => trayManager.setIcon(any(), isTemplate: any(named: 'isTemplate')),
      );
      verifyNever(() => trayManager.setContextMenu(any()));
      verifyNever(() => windowManager.ensureInitialized());
      verifyNever(() => windowManager.setPreventClose(any()));
    });
  });
}
