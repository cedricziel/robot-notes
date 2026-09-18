import 'package:app/src/desktop/window_chrome_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:window_manager/window_manager.dart';

class MockWindowManager extends Mock implements WindowManager {}

void main() {
  late MockWindowManager windowManager;

  setUpAll(() {
    registerFallbackValue(TitleBarStyle.hidden);
  });

  setUp(() {
    windowManager = MockWindowManager();

    when(() => windowManager.ensureInitialized()).thenAnswer((_) async {});
    when(
      () => windowManager.setTitleBarStyle(
        any(),
        windowButtonVisibility: any(named: 'windowButtonVisibility'),
      ),
    ).thenAnswer((_) async {});
    when(() => windowManager.startDragging()).thenAnswer((_) async {});
    when(() => windowManager.isMaximized()).thenAnswer((_) async => false);
    when(() => windowManager.maximize()).thenAnswer((_) async {});
    when(() => windowManager.unmaximize()).thenAnswer((_) async {});
  });

  WindowChromeController buildController({bool isMacOS = true}) {
    return WindowChromeController(
      windowManager: windowManager,
      isMacOS: isMacOS,
    );
  }

  group('WindowChromeController on macOS', () {
    test('init switches the native window to the hidden (unified) title-bar '
        'style with the traffic lights kept visible', () async {
      final controller = buildController();

      await controller.init();

      verify(() => windowManager.ensureInitialized()).called(1);
      verify(
        () => windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: true,
        ),
      ).called(1);
    });
  });

  group('WindowChromeController off macOS', () {
    test('init is a no-op', () async {
      final controller = buildController(isMacOS: false);

      await controller.init();

      verifyNever(() => windowManager.ensureInitialized());
      verifyNever(
        () => windowManager.setTitleBarStyle(
          any(),
          windowButtonVisibility: any(named: 'windowButtonVisibility'),
        ),
      );
    });
  });

  group('startWindowDrag', () {
    test('starts a native window drag', () async {
      await startWindowDrag(windowManager: windowManager);

      verify(() => windowManager.startDragging()).called(1);
    });
  });

  group('toggleWindowZoom', () {
    test('maximizes an un-maximized window', () async {
      when(() => windowManager.isMaximized()).thenAnswer((_) async => false);

      await toggleWindowZoom(windowManager: windowManager);

      verify(() => windowManager.maximize()).called(1);
      verifyNever(() => windowManager.unmaximize());
    });

    test('un-maximizes an already-maximized window', () async {
      when(() => windowManager.isMaximized()).thenAnswer((_) async => true);

      await toggleWindowZoom(windowManager: windowManager);

      verify(() => windowManager.unmaximize()).called(1);
      verifyNever(() => windowManager.maximize());
    });
  });
}
