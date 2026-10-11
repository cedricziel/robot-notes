import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_editor/super_editor.dart';

import '../lib/src/adaptive_editor.dart';

void main() {
  testWidgets('opening without a caret does not focus or mutate the document', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final scene = await mount(
      tester,
      initialSelection: false,
      focusEditor: false,
    );
    final data = editableNode(tester)!.getSemanticsData();
    handle.dispose();
    expect(tester.takeException(), isNull);
    expect(data.textSelection, isNull);
    expect(scene.composer.selection, isNull);
    expect((scene.document.first as ParagraphNode).text.toPlainText(), 'First');
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('task checkbox renders and changes through the editor pipeline', (
    tester,
  ) async {
    final scene = await mount(tester, extraTask: true);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(legacy.Checkbox));
    await tester.pump();
    expect((scene.document.getNodeById('task') as TaskNode).isComplete, isTrue);
  });

  testWidgets('semantics report editable document text and focused selection', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final scene = await mount(tester);
    final node = editableNode(tester);
    final data = node!.getSemanticsData();
    handle.dispose();

    expect(data.value, 'First\n~\nLast');
    expect(node.flagsCollection.isFocused, Tristate.isTrue);
    expect(data.textSelection, const TextSelection.collapsed(offset: 0));
    expect(scene.composer.selection!.extent.nodeId, 'first');
  });

  testWidgets(
    'accessibility edits preserve formatting and opaque source and support undo',
    (tester) async {
      final handle = tester.ensureSemantics();
      final scene = await mount(tester);
      final node = editableNode(tester)!;
      tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.setText,
        'First changed\n~\nLast',
      );
      await tester.pump();
      handle.dispose();

      expect(
        (scene.document.first as ParagraphNode).text.toPlainText(),
        'First changed',
      );
      expect(
        (scene.document.first as ParagraphNode).text.hasAttributionAt(
          0,
          attribution: boldAttribution,
        ),
        isTrue,
      );
      expect(
        scene.document.getNodeById('opaque')!.getMetadataValue('source'),
        '| A | B |\r\n',
      );
      scene.editor.undo();
      expect(
        (scene.document.first as ParagraphNode).text.toPlainText(),
        'First',
      );
    },
  );

  testWidgets('accessibility selection spans blocks in both directions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final scene = await mount(tester);
    tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
      editableNode(tester)!.id,
      SemanticsAction.setSelection,
      {'base': 12, 'extent': 1},
    );
    await tester.pump();
    handle.dispose();

    expect(
      scene.composer.selection,
      const DocumentSelection(
        base: DocumentPosition(
          nodeId: 'last',
          nodePosition: TextNodePosition(offset: 4),
        ),
        extent: DocumentPosition(
          nodeId: 'first',
          nodePosition: TextNodePosition(offset: 1),
        ),
      ),
    );
  });

  testWidgets('accessibility insertion creates paragraph boundaries', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final scene = await mount(tester);
    tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
      editableNode(tester)!.id,
      SemanticsAction.setText,
      'Fi\nrst\n~\nLast',
    );
    await tester.pump();
    handle.dispose();

    expect(scene.document.nodeCount, 4);
    expect((scene.document.first as ParagraphNode).text.toPlainText(), 'Fi');
    expect(
      (scene.document.getNodeAt(1) as ParagraphNode).text.toPlainText(),
      'rst',
    );
    expect(
      scene.document.getNodeById('opaque')!.getMetadataValue('source'),
      '| A | B |\r\n',
    );
  });

  testWidgets('accessible character movement respects emoji boundaries', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final scene = await mount(tester);
    final owner = tester.binding.renderViews.single.owner!.semanticsOwner!;
    owner.performAction(
      editableNode(tester)!.id,
      SemanticsAction.setText,
      '😀First\n~\nLast',
    );
    await tester.pump();
    owner.performAction(
      editableNode(tester)!.id,
      SemanticsAction.setSelection,
      {'base': 0, 'extent': 0},
    );
    await tester.pump();
    final node = editableNode(tester)!;
    final supportsMovement = node.getSemanticsData().hasAction(
      SemanticsAction.moveCursorForwardByCharacter,
    );
    owner.performAction(
      node.id,
      SemanticsAction.moveCursorForwardByCharacter,
      false,
    );
    await tester.pump();
    handle.dispose();

    expect(supportsMovement, isTrue);
    expect(
      scene.composer.selection!.extent.nodePosition,
      const TextNodePosition(offset: 2),
    );
  });

  testWidgets('document typography follows the adaptive host', (tester) async {
    await mount(tester);
    final text = tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == 'First',
      ),
    );
    expect(text.text.style!.fontSize, 23);
    expect(text.text.style!.color, ThemeData.dark().colorScheme.onSurface);
  });

  testWidgets('read-only semantics allow selection but cannot mutate content', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final scene = await mount(tester, readOnly: true);
    final node = editableNode(tester)!;
    final data = node.getSemanticsData();
    tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.setText,
      'Replacement',
    );
    await tester.pump();
    handle.dispose();

    expect(node.flagsCollection.isReadOnly, isTrue);
    expect(data.hasAction(SemanticsAction.setText), isFalse);
    expect((scene.document.first as ParagraphNode).text.toPlainText(), 'First');
    expect(find.byType(SuperEditor), findsNothing);
    expect(find.byType(SuperReader), findsOneWidget);
  });
}

SemanticsNode? editableNode(WidgetTester tester) {
  SemanticsNode? result;
  void visit(SemanticsNode node) {
    if (node.flagsCollection.isTextField) result = node;
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.single.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  expect(
    result,
    isNotNull,
    reason: 'Document must expose editable text semantics.',
  );
  return result;
}

Future<
  ({MutableDocument document, MutableDocumentComposer composer, Editor editor})
>
mount(
  WidgetTester tester, {
  bool readOnly = false,
  bool initialSelection = true,
  bool focusEditor = true,
  bool extraTask = false,
}) async {
  final text = AttributedText('First')
    ..addAttribution(boldAttribution, const SpanRange(0, 4));
  final document = MutableDocument(
    nodes: [
      ParagraphNode(id: 'first', text: text),
      HorizontalRuleNode(id: 'opaque', metadata: {'source': '| A | B |\r\n'}),
      ParagraphNode(id: 'last', text: AttributedText('Last')),
      if (extraTask)
        TaskNode(
          id: 'task',
          text: AttributedText('Do work'),
          isComplete: false,
        ),
    ],
  );
  final composer = MutableDocumentComposer(
    initialSelection: initialSelection
        ? const DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: 'first',
              nodePosition: TextNodePosition(offset: 0),
            ),
          )
        : null,
  );
  final editor = createDefaultDocumentEditor(
    document: document,
    composer: composer,
    isHistoryEnabled: true,
  );
  final focus = FocusNode();
  addTearDown(editor.dispose);
  addTearDown(composer.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        textTheme: ThemeData.dark().textTheme.copyWith(
          bodyLarge: const TextStyle(fontSize: 23),
        ),
      ),
      home: Scaffold(
        body: AdaptiveSuperEditor(
          editor: editor,
          document: document,
          composer: composer,
          focusNode: focus,
          readOnly: readOnly,
          inputSource: TextInputSource.keyboard,
        ),
      ),
    ),
  );
  if (focusEditor) focus.requestFocus();
  await tester.pump();
  return (document: document, composer: composer, editor: editor);
}
