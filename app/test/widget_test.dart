import 'package:app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smoke test: the app boots without crashing and renders the splash while
/// the persisted config is being read. Real screen-level coverage lives in
/// `test/src/**/*_test.dart`; the bootstrap path itself is integration-shaped
/// (it touches `flutter_secure_storage`) so we only assert the initial frame
/// here.
void main() {
  testWidgets('boots into the splash on first frame', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: RobotNotesApp()));

    // First frame: FutureBuilder is still resolving, so we see the splash.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
