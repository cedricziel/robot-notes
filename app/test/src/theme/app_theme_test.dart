import 'package:app/src/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
        AppTheme.light(
          platform: TargetPlatform.android,
        ).appBarTheme.centerTitle,
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
