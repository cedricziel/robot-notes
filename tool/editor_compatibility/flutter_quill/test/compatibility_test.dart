import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as ui;

import '../../../../app/lib/src/widgets/adaptive.dart';
import '../../../../app/lib/src/widgets/platform_motion.dart';

import 'package:robot_notes_editor_compatibility/adaptive_host_checks.dart';

void main() {
  adaptiveHostChecks(useCupertino: useCupertino);
  test('cross-block deletion can be undone', () {
    final controller = QuillController(
      document: Document.fromJson([
        {'insert': 'First\nSecond\n'},
      ]),
      selection: const ui.TextSelection(baseOffset: 2, extentOffset: 9),
    );
    addTearDown(controller.dispose);

    controller.replaceText(
      2,
      7,
      '',
      const ui.TextSelection.collapsed(offset: 2),
    );
    expect(controller.document.toPlainText(), 'Fiond\n');
    controller.undo();

    expect(controller.document.toPlainText(), 'First\nSecond\n');
  });

  test('editing text preserves a custom opaque source embed', () {
    const rawSource = '| A | B |\r\n|---|---|\r\n| 1 | 2 |\r\n';
    final controller = QuillController(
      document: Document.fromJson([
        {'insert': 'First\n'},
        {
          'insert': {'opaque-source': rawSource},
        },
        {'insert': '\n'},
      ]),
      selection: const ui.TextSelection.collapsed(offset: 5),
    );
    addTearDown(controller.dispose);

    controller.replaceText(
      5,
      0,
      ' changed',
      const ui.TextSelection.collapsed(offset: 13),
    );
    controller.undo();
    controller.redo();

    expect(controller.document.toDelta().toJson(), [
      {'insert': 'First changed\n'},
      {
        'insert': {'opaque-source': rawSource},
      },
      {'insert': '\n'},
    ]);
  });

  testWidgets('hardware arrow moves the caret inside the document', (
    tester,
  ) async {
    final scene = await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(scene.controller.selection.extentOffset, 1);
  });

  testWidgets('IME composition survives a host rebuild and editor removal', (
    tester,
  ) async {
    final scene = await _mount(tester);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.updateEditingValue(
      const ui.TextEditingValue(
        text: 'にFirst paragraph\n',
        selection: ui.TextSelection.collapsed(offset: 1),
        composing: ui.TextRange(start: 0, end: 1),
      ),
    );
    await tester.pump();
    scene.rebuild();
    await tester.pump();

    expect(scene.controller.document.toPlainText(), 'にFirst paragraph\n');
    final raw = tester.state<QuillRawEditorState>(find.byType(QuillRawEditor));
    expect(
      raw.currentTextEditingValue!.composing,
      const ui.TextRange(start: 0, end: 1),
    );
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.pumpWidget(const ui.SizedBox());
    expect(tester.takeException(), isNull);
  }, tags: 'compatibility_gate');

  testWidgets('shared block actions open and dismiss through touch', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(find.byTooltip('Block actions'));
    await tester.pumpAndSettle();
    expect(find.text('Move up'), findsOneWidget);
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(find.text('Move up'), findsNothing);
  });

  testWidgets('shared link dialog opens above the mounted editor', (
    tester,
  ) async {
    await _mount(tester);
    final dialog = showPlatformDialog<void>(
      context: tester.element(find.byType(QuillEditor)),
      builder: (context) => ui.AlertDialog.adaptive(
        title: const ui.Text('Edit link'),
        content: AdaptiveDialogTextField(
          label: 'URL',
          hint: 'https://',
          autofocus: false,
          onChanged: (_) {},
        ),
        actions: [
          adaptiveDialogAction(
            context,
            onPressed: () => ui.Navigator.of(context).pop(),
            child: const ui.Text('Cancel'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveDialogTextField), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await dialog;
    expect(find.byType(AdaptiveDialogTextField), findsNothing);
    expect(find.byType(QuillEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor exposes editable text semantics in the adaptive host', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _mount(tester);

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Block actions'), findsOneWidget);
    final editable = exposesEditableText(tester);
    semantics.dispose();
    expect(
      editable,
      isTrue,
      reason: 'A screen reader must recognize the editable document.',
    );
  }, tags: 'compatibility_gate');
}

Future<({QuillController controller, ui.VoidCallback rebuild})> _mount(
  WidgetTester tester,
) async {
  final controller = QuillController(
    document: Document.fromJson([
      {'insert': 'First paragraph\n'},
    ]),
    selection: const ui.TextSelection.collapsed(offset: 0),
  );
  final focus = ui.FocusNode();
  final scroll = ui.ScrollController();
  late ui.StateSetter hostSetState;
  addTearDown(controller.dispose);
  addTearDown(focus.dispose);
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    ui.MaterialApp(
      theme: ui.ThemeData.dark().copyWith(platform: ui.TargetPlatform.macOS),
      localizationsDelegates: const [FlutterQuillLocalizations.delegate],
      home: ui.Scaffold(
        body: ui.StatefulBuilder(
          builder: (context, setState) {
            hostSetState = setState;
            return ui.Column(
              children: [
                AdaptiveMoreMenu(
                  tooltip: 'Block actions',
                  entries: [
                    AdaptiveMenuEntry(label: 'Move up', onSelected: () {}),
                  ],
                ),
                ui.Expanded(
                  child: QuillEditor(
                    controller: controller,
                    focusNode: focus,
                    scrollController: scroll,
                    config: const QuillEditorConfig(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  focus.requestFocus();
  await tester.pump();
  return (controller: controller, rebuild: () => hostSetState(() {}));
}
