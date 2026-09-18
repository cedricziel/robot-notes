import 'package:app/src/desktop/mac_window_chrome.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs [body] with the target platform pinned, resetting it inline (not
/// in a tearDown): the test binding checks the override is clear before
/// tearDowns run.
Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Widget _hostedIn(
  Widget child, {
  EdgeInsets padding = EdgeInsets.zero,
  ValueChanged<DragStartDetails>? onDragStart,
  VoidCallback? onDoubleTap,
}) {
  return MediaQuery(
    data: MediaQueryData(padding: padding),
    child: MaterialApp(
      home: SizedBox.expand(
        child: MacWindowChrome(
          onDragStart: onDragStart,
          onDoubleTap: onDoubleTap,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  group('MacWindowChrome on macOS', () {
    testWidgets('raises the top padding to the title-bar inset', (
      tester,
    ) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        double? readTop;
        await tester.pumpWidget(
          _hostedIn(
            Builder(
              builder: (context) {
                readTop = MediaQuery.paddingOf(context).top;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        expect(readTop, kMacTitleBarInset);
      });
    });

    testWidgets('keeps a pre-existing larger top padding', (tester) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        double? readTop;
        await tester.pumpWidget(
          _hostedIn(
            Builder(
              builder: (context) {
                readTop = MediaQuery.paddingOf(context).top;
                return const SizedBox.shrink();
              },
            ),
            padding: const EdgeInsets.only(top: 40),
          ),
        );

        expect(readTop, 40);
      });
    });

    testWidgets(
      'draws a full-width drag strip the height of the inset, at the top',
      (tester) async {
        await _onPlatform(TargetPlatform.macOS, () async {
          await tester.pumpWidget(_hostedIn(const SizedBox.shrink()));

          final strip = find.byKey(const Key('window.dragStrip'));
          expect(strip, findsOneWidget);
          expect(tester.getTopLeft(strip), Offset.zero);
          expect(tester.getSize(strip).height, kMacTitleBarInset);
          expect(
            tester.getSize(strip).width,
            tester.getSize(find.byType(MaterialApp)).width,
          );
        });
      },
    );

    testWidgets('a pan on the strip starts a window drag', (tester) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        var dragStarted = false;
        await tester.pumpWidget(
          _hostedIn(
            const SizedBox.shrink(),
            onDragStart: (_) => dragStarted = true,
          ),
        );

        await tester.drag(
          find.byKey(const Key('window.dragStrip')),
          const Offset(20, 0),
        );
        // Flushes the double-tap recognizer's pending timer so the test
        // binding doesn't see it as a leaked timer on teardown.
        await tester.pump(const Duration(milliseconds: 500));

        expect(dragStarted, isTrue);
      });
    });

    testWidgets('a double-tap on the strip toggles zoom', (tester) async {
      await _onPlatform(TargetPlatform.macOS, () async {
        var doubleTapped = false;
        await tester.pumpWidget(
          _hostedIn(
            const SizedBox.shrink(),
            onDoubleTap: () => doubleTapped = true,
          ),
        );

        final strip = find.byKey(const Key('window.dragStrip'));
        await tester.tap(strip);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(strip);
        await tester.pumpAndSettle();

        expect(doubleTapped, isTrue);
      });
    });
  });

  group('MacWindowChrome off macOS', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('leaves padding and content untouched on $platform', (
        tester,
      ) async {
        await _onPlatform(platform, () async {
          double? readTop;
          await tester.pumpWidget(
            _hostedIn(
              Builder(
                builder: (context) {
                  readTop = MediaQuery.paddingOf(context).top;
                  return const SizedBox.shrink();
                },
              ),
              padding: const EdgeInsets.only(top: 12),
            ),
          );

          expect(readTop, 12);
          expect(find.byKey(const Key('window.dragStrip')), findsNothing);
        });
      });
    }
  });
}
