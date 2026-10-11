import 'package:app/src/settings/app_preferences.dart';
import 'package:app/src/settings/appearance_control.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Apple appearance options select and persist the theme',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: AppearanceControl(preferences: preferences),
              ),
            ),
          ),
        ),
      );
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(preferences.themeMode, ThemeMode.dark);
      expect(
        tester
            .widget<CupertinoSlidingSegmentedControl<ThemeMode>>(
              find.byType(CupertinoSlidingSegmentedControl<ThemeMode>),
            )
            .groupValue,
        ThemeMode.dark,
      );
      final reloaded = AppPreferences();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.themeMode, ThemeMode.dark);
      await tester.tap(find.text('System'));
      await tester.pumpAndSettle();
      expect(preferences.themeMode, ThemeMode.system);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }),
  );

  testWidgets(
    'Material appearance chooser still updates the preference',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AppearanceControl(preferences: preferences)),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<ThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light').last);
      await tester.pumpAndSettle();
      expect(preferences.themeMode, ThemeMode.light);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
