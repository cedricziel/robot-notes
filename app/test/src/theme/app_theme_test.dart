import 'package:app/src/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
// Legacy imports intentionally verify interop with unmigrated dependencies.
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isApplePlatform', () {
    test('is true for iOS and macOS only', () {
      expect(isApplePlatform(TargetPlatform.iOS), isTrue);
      expect(isApplePlatform(TargetPlatform.macOS), isTrue);
      expect(isApplePlatform(TargetPlatform.android), isFalse);
      expect(isApplePlatform(TargetPlatform.windows), isFalse);
      expect(isApplePlatform(TargetPlatform.linux), isFalse);
    });
  });

  group('AppTheme', () {
    test('uses neutral surfaces and a clear indigo accent', () {
      final light = AppTheme.light(platform: TargetPlatform.macOS);
      final dark = AppTheme.dark(platform: TargetPlatform.macOS);

      expect(light.scaffoldBackgroundColor, const Color(0xFFF5F6F9));
      expect(light.colorScheme.surface, Colors.white);
      expect(light.colorScheme.primary, const Color(0xFF3659E3));
      expect(light.colorScheme.surfaceTint, Colors.transparent);
      expect(dark.scaffoldBackgroundColor, const Color(0xFF17191F));
      expect(dark.colorScheme.surface, const Color(0xFF20232B));
      expect(dark.colorScheme.onSurface, const Color(0xFFE8EBF2));
    });

    test(
      'uses rounded rectangles for controls and panels on every platform',
      () {
        for (final platform in TargetPlatform.values) {
          for (final theme in [
            AppTheme.light(platform: platform),
            AppTheme.dark(platform: platform),
          ]) {
            final buttonShape = theme.filledButtonTheme.style!.shape!.resolve(
              {},
            );
            expect(buttonShape, isA<RoundedRectangleBorder>());
            expect(
              (buttonShape! as RoundedRectangleBorder).borderRadius,
              BorderRadius.circular(8),
            );
            final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
            expect(cardShape.borderRadius, BorderRadius.circular(12));
            expect(cardShape.side.color, theme.colorScheme.outlineVariant);
            expect(theme.cardTheme.elevation, 0);
            final inputBorder =
                theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
            expect(inputBorder.borderRadius, BorderRadius.circular(8));
            expect(inputBorder.borderSide.color, theme.colorScheme.primary);
          }
        }
      },
    );

    test('records the platform it was built for', () {
      expect(
        AppTheme.light(platform: TargetPlatform.macOS).platform,
        TargetPlatform.macOS,
      );
      expect(
        AppTheme.dark(platform: TargetPlatform.android).platform,
        TargetPlatform.android,
      );
    });

    test('turns ink ripples off on Apple platforms only', () {
      expect(
        AppTheme.light(platform: TargetPlatform.iOS).splashFactory,
        NoSplash.splashFactory,
      );
      expect(
        AppTheme.dark(platform: TargetPlatform.macOS).splashFactory,
        NoSplash.splashFactory,
      );
      expect(
        AppTheme.light(platform: TargetPlatform.android).splashFactory,
        isNot(NoSplash.splashFactory),
      );
    });

    test('centers app bar titles on iOS, leading-aligns them elsewhere', () {
      expect(
        AppTheme.light(platform: TargetPlatform.iOS).appBarTheme.centerTitle,
        isTrue,
      );
      expect(
        AppTheme.light(platform: TargetPlatform.macOS).appBarTheme.centerTitle,
        isFalse,
      );
      expect(
        AppTheme.light(platform: TargetPlatform.android)
            .appBarTheme
            .centerTitle,
        isFalse,
      );
    });

    test('defaults to the ambient target platform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(AppTheme.light().platform, TargetPlatform.iOS);
        expect(AppTheme.light().splashFactory, NoSplash.splashFactory);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('uses Menlo for code on Apple platforms', () {
      expect(AppTheme.codeFont(TargetPlatform.iOS).fontFamily, 'Menlo');
      expect(AppTheme.codeFont(TargetPlatform.macOS).fontFamily, 'Menlo');
      expect(AppTheme.codeFont(TargetPlatform.android).fontFamily, 'monospace');
      expect(
        AppTheme.codeFont(TargetPlatform.windows).fontFamilyFallback,
        contains('Consolas'),
      );
    });

    for (final platform in TargetPlatform.values) {
      for (final dark in [false, true]) {
        testWidgets('legacy Markdown theme bridge: $platform dark=$dark', (
          tester,
        ) async {
          final theme = dark
              ? AppTheme.dark(platform: platform)
              : AppTheme.light(platform: platform);
          legacy.ThemeData? dependencyTheme;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              // Keep this regression until flutter_markdown_plus migrates.
              builder: (context, child) =>
                  // ignore: deprecated_member_use
                  MaterialUiCompatibilityBridge(child: child!),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    dependencyTheme = legacy.Theme.of(context);
                    return MarkdownBody(
                      data: '**Readable** text\n\n- [x] Done\n\n> Quote',
                      styleSheet: AppTheme.markdown(context),
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(dependencyTheme!.platform, platform);
          expect(dependencyTheme!.brightness, theme.brightness);
          expect(
            dependencyTheme!.colorScheme.onSurface,
            theme.colorScheme.onSurface,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('dark Markdown checkboxes use the visible accent', (
      tester,
    ) async {
      Color? checkboxColor;
      final theme = AppTheme.dark(platform: TargetPlatform.macOS);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              checkboxColor = AppTheme.markdown(context).checkbox?.color;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(checkboxColor, theme.colorScheme.primary);
    });

    testWidgets('the Markdown stylesheet follows the theme platform', (
      tester,
    ) async {
      String? codeFamily;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(platform: TargetPlatform.macOS),
          home: Builder(
            builder: (context) {
              codeFamily = AppTheme.markdown(context).code?.fontFamily;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(codeFamily, 'Menlo');
    });
  });
}
