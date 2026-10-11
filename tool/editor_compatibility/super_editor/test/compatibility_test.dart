import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as ui;
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart' show imeClientGetter;

import '../../../../app/lib/src/widgets/adaptive.dart';
import '../../../../app/lib/src/widgets/platform_motion.dart';

import 'package:robot_notes_editor_compatibility/adaptive_host_checks.dart';

void main() {
  adaptiveHostChecks(useCupertino: useCupertino);
  test('cross-block deletion can be undone with node identities restored', () {
    final document = MutableDocument(
      nodes: [
        ParagraphNode(id: 'first', text: AttributedText('First')),
        ParagraphNode(id: 'second', text: AttributedText('Second')),
      ],
    );
    final composer = MutableDocumentComposer();
    final editor = createDefaultDocumentEditor(
      document: document,
      composer: composer,
      isHistoryEnabled: true,
    );
    addTearDown(editor.dispose);
    addTearDown(composer.dispose);
    editor.execute([
      const ChangeSelectionRequest(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: 'first',
            nodePosition: TextNodePosition(offset: 2),
          ),
          extent: DocumentPosition(
            nodeId: 'second',
            nodePosition: TextNodePosition(offset: 3),
          ),
        ),
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
    ]);

    editor.execute([const DeleteSelectionRequest(ui.TextAffinity.downstream)]);
    expect(document.nodeCount, 1);
    expect((document.first as ParagraphNode).text.toPlainText(), 'Fiond');
    editor.undo();

    expect(document.nodeCount, 2);
    expect(
      (document.getNodeById('first') as ParagraphNode).text.toPlainText(),
      'First',
    );
    expect(
      (document.getNodeById('second') as ParagraphNode).text.toPlainText(),
      'Second',
    );
  });

  test('editing text preserves source attached to an opaque node', () {
    const rawSource = '| A | B |\r\n|---|---|\r\n| 1 | 2 |\r\n';
    final document = MutableDocument(
      nodes: [
        ParagraphNode(id: 'first', text: AttributedText('First')),
        _OpaqueSourceNode(id: 'table', source: rawSource),
      ],
    );
    final composer = MutableDocumentComposer();
    final editor = createDefaultDocumentEditor(
      document: document,
      composer: composer,
      isHistoryEnabled: true,
    );
    addTearDown(editor.dispose);
    addTearDown(composer.dispose);

    editor.execute([
      InsertTextRequest(
        documentPosition: DocumentPosition(
          nodeId: 'first',
          nodePosition: TextNodePosition(offset: 5),
        ),
        textToInsert: ' changed',
        attributions: {},
      ),
    ]);
    editor.undo();
    editor.redo();

    expect(
      (document.getNodeById('table') as _OpaqueSourceNode).source,
      rawSource,
    );
    expect(
      (document.first as ParagraphNode).text.toPlainText(),
      'First changed',
    );
  });

  testWidgets('hardware arrow moves the caret inside the document', (
    tester,
  ) async {
    final scene = await _mount(tester, source: TextInputSource.keyboard);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(
      scene.composer.selection!.extent.nodePosition,
      const TextNodePosition(offset: 1),
    );
  });

  testWidgets('IME composition survives a host rebuild', (tester) async {
    final scene = await _mount(tester, source: TextInputSource.ime);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    final oldText = tester.testTextInput.editingState!['text'] as String;
    final offset = tester.testTextInput.editingState!['selectionExtent'] as int;
    imeClientGetter().updateEditingValueWithDeltas([
      TextEditingDeltaInsertion(
        oldText: oldText,
        textInserted: 'に',
        insertionOffset: offset,
        selection: ui.TextSelection.collapsed(offset: offset + 1),
        composing: ui.TextRange(start: offset, end: offset + 1),
      ),
    ]);
    await tester.pump();
    scene.rebuild();
    await tester.pump();

    expect(
      (scene.document.first as ParagraphNode).text.toPlainText(),
      'にFirst paragraph',
    );
    expect(scene.composer.composingRegion.value, isNotNull);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('shared block actions open and dismiss through touch', (
    tester,
  ) async {
    await _mount(tester, source: TextInputSource.keyboard);
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
    await _mount(tester, source: TextInputSource.keyboard);
    final dialog = showPlatformDialog<void>(
      context: tester.element(find.byType(SuperEditor)),
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
    expect(find.byType(SuperEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor exposes editable text semantics in the adaptive host', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _mount(tester, source: TextInputSource.keyboard);

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

Future<
  ({
    MutableDocument document,
    MutableDocumentComposer composer,
    ui.VoidCallback rebuild,
  })
>
_mount(WidgetTester tester, {required TextInputSource source}) async {
  final document = MutableDocument(
    nodes: [
      ParagraphNode(id: 'first', text: AttributedText('First paragraph')),
    ],
  );
  final composer = MutableDocumentComposer();
  final editor = createDefaultDocumentEditor(
    document: document,
    composer: composer,
    isHistoryEnabled: true,
  );
  final focus = ui.FocusNode();
  late ui.StateSetter hostSetState;
  addTearDown(editor.dispose);
  addTearDown(composer.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    ui.MaterialApp(
      theme: ui.ThemeData.dark().copyWith(platform: ui.TargetPlatform.macOS),
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
                  child: SuperEditor(
                    editor: editor,
                    focusNode: focus,
                    gestureMode: DocumentGestureMode.mouse,
                    inputSource: source,
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
  editor.execute([
    const ChangeSelectionRequest(
      DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: 'first',
          nodePosition: TextNodePosition(offset: 0),
        ),
      ),
      SelectionChangeType.placeCaret,
      SelectionReason.userInteraction,
    ),
  ]);
  await tester.pump();
  return (
    document: document,
    composer: composer,
    rebuild: () => hostSetState(() {}),
  );
}

class _OpaqueSourceNode extends BlockNode {
  _OpaqueSourceNode({required this.id, required this.source, super.metadata});

  @override
  final String id;
  final String source;

  @override
  String? copyContent(dynamic selection) => source;

  @override
  bool hasEquivalentContent(DocumentNode other) =>
      other is _OpaqueSourceNode && other.source == source;

  @override
  DocumentNode copyWithAddedMetadata(Map<String, dynamic> newProperties) =>
      _OpaqueSourceNode(
        id: id,
        source: source,
        metadata: {...metadata, ...newProperties},
      );

  @override
  DocumentNode copyAndReplaceMetadata(Map<String, dynamic> newMetadata) =>
      _OpaqueSourceNode(id: id, source: source, metadata: newMetadata);
}
