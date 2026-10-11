import 'package:flutter/material.dart' as legacy;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as ui;

bool exposesEditableText(WidgetTester tester) {
  final root = tester
      .binding
      .renderViews
      .single
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  var found = false;
  void collect(SemanticsNode node) {
    found = found || node.flagsCollection.isTextField;
    node.visitChildren((child) {
      collect(child);
      return true;
    });
  }

  collect(root);
  return found;
}

void adaptiveHostChecks({
  required bool Function(ui.BuildContext) useCupertino,
}) {
  testWidgets('standard adaptive-host text field exposes editable semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const ui.MaterialApp(home: ui.Scaffold(body: ui.TextField())),
    );

    final editable = exposesEditableText(tester);
    semantics.dispose();
    await tester.pumpWidget(const ui.SizedBox());
    expect(editable, isTrue);
  });

  testWidgets('legacy theme lookup follows the adaptive host theme', (
    tester,
  ) async {
    legacy.ThemeData? editorTheme;
    bool? appleControls;
    await tester.pumpWidget(
      ui.MaterialApp(
        theme: ui.ThemeData.dark().copyWith(platform: ui.TargetPlatform.iOS),
        home: ui.Builder(
          builder: (context) {
            editorTheme = legacy.Theme.of(context);
            appleControls = useCupertino(context);
            return const ui.SizedBox();
          },
        ),
      ),
    );

    expect(appleControls, isTrue);
    expect(editorTheme!.brightness, ui.Brightness.dark);
    expect(editorTheme!.platform, ui.TargetPlatform.iOS);
  }, tags: 'compatibility_gate');
}
