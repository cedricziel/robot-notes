import 'package:app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies the app follows the platform's brightness automatically, since
/// there is no in-app toggle for it.
void main() {
  testWidgets('resolves a dark ColorScheme when the platform is dark', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const RobotNotesApp());

    final context = tester.element(find.byType(CircularProgressIndicator));
    expect(Theme.of(context).colorScheme.brightness, Brightness.dark);
  });

  testWidgets('resolves a light ColorScheme when the platform is light', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const RobotNotesApp());

    final context = tester.element(find.byType(CircularProgressIndicator));
    expect(Theme.of(context).colorScheme.brightness, Brightness.light);
  });
}
