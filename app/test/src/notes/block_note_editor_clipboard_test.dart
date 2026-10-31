import 'dart:async';

import 'package:adaptive_super_editor/adaptive_super_editor.dart';
import 'package:app/src/notes/block_note_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_editor/super_editor.dart';

void main() {
  testWidgets('code paste is literal and keeps newlines inside the fence', (
    tester,
  ) async {
    final fixture = _Fixture('```dart\nhello\n```');
    await fixture.mount(tester);
    final scene = fixture.scene(tester);
    scene.editor.execute([
      PasteEditorRequest(
        content: ' **bold**\nnext',
        pastePosition: DocumentPosition(
          nodeId: scene.document.first.id,
          nodePosition: const TextNodePosition(offset: 5),
        ),
      ),
    ]);
    expect(fixture.markdown, '```dart\nhello **bold**\nnext\n```');
    scene.editor.undo();
    expect(fixture.markdown, '```dart\nhello\n```');
  });

  for (final source in [
    '# hello',
    '- hello',
    '1. hello',
    '- [ ] hello',
    '> hello',
  ]) {
    testWidgets('inline paste preserves block type in $source', (tester) async {
      final fixture = _Fixture(source);
      await fixture.mount(tester);
      final scene = fixture.scene(tester);
      scene.editor.execute([
        PasteEditorRequest(
          content: ' world',
          pastePosition: DocumentPosition(
            nodeId: scene.document.first.id,
            nodePosition: const TextNodePosition(offset: 5),
          ),
        ),
      ]);
      expect(fixture.markdown, '$source world');
      expect(scene.document.nodeCount, 1);
    });
  }

  testWidgets('pending paste cannot replace a newer source draft', (
    tester,
  ) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester);
    fixture.update(() => fixture.sourceMode = true);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('block-source')),
      'Newer source draft',
    );
    fixture.clipboard.complete({'text': ' pasted'});
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Newer source draft');
    expect(fixture.source.text, 'Newer source draft');
    expect(fixture.changes, ['Newer source draft']);
  });

  testWidgets('pending paste cannot mutate a read-only editor', (tester) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester);
    fixture.update(() => fixture.readOnly = true);
    await tester.pump();
    fixture.clipboard.complete({'text': ' pasted'});
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Draft');
    expect(fixture.changes, isEmpty);
  });

  testWidgets('pending paste is cancelled after a source round trip', (
    tester,
  ) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester);
    fixture.update(() => fixture.sourceMode = true);
    await tester.pump();
    await tester.tap(find.text('Back to Blocks'));
    await tester.pumpAndSettle();
    fixture.clipboard.complete({'text': ' pasted'});
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Draft');
    expect(fixture.changes, isEmpty);
  });

  testWidgets('clipboard wait leaves an expanded selection intact', (
    tester,
  ) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester, start: 0);
    expect(fixture.markdown, 'Draft');
    fixture.clipboard.complete({'text': 'Replacement'});
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Replacement');
    fixture.scene(tester).editor.undo();
    expect(fixture.markdown, 'Draft');
  });

  testWidgets('empty clipboard does not delete selected content', (
    tester,
  ) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester, start: 0);
    fixture.clipboard.complete(null);
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Draft');
    expect(fixture.changes, isEmpty);
  });

  testWidgets('pending paste is cancelled by intervening document edits', (
    tester,
  ) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester);
    fixture.scene(tester).editor.execute([
      const InsertPlainTextAtCaretRequest(' newer'),
    ]);
    await tester.pump();
    fixture.clipboard.complete({'text': ' pasted'});
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Draft newer');
  });

  testWidgets('pending paste is cancelled after a read-only round trip', (
    tester,
  ) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester);
    fixture.update(() => fixture.readOnly = true);
    await tester.pump();
    fixture.update(() => fixture.readOnly = false);
    await tester.pump();
    fixture.clipboard.complete({'text': ' pasted'});
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Draft');
    expect(fixture.changes, isEmpty);
  });

  testWidgets('caret movement cancels a pending paste', (tester) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester);
    final scene = fixture.scene(tester);
    scene.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: scene.document.first.id,
            nodePosition: const TextNodePosition(offset: 0),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
    fixture.clipboard.complete({'text': ' pasted'});
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Draft');
    expect(fixture.changes, isEmpty);
  });

  testWidgets('clipboard failure does not delete selected content', (
    tester,
  ) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester, start: 0);
    fixture.clipboard.completeError(
      PlatformException(code: 'clipboard_unavailable'),
    );
    await tester.pumpAndSettle();
    expect(fixture.markdown, 'Draft');
    expect(fixture.changes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending paste after disposal has no callback or error', (
    tester,
  ) async {
    final fixture = _Fixture('Draft');
    await fixture.mount(tester);
    await fixture.beginPaste(tester);
    await tester.pumpWidget(const SizedBox());
    fixture.clipboard.complete({'text': ' pasted'});
    await tester.pumpAndSettle();
    expect(fixture.changes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _Fixture {
  _Fixture(this.markdown) : source = TextEditingController(text: markdown);
  String markdown;
  bool sourceMode = false;
  bool readOnly = false;
  final TextEditingController source;
  final clipboard = Completer<Map<String, String>?>();
  final changes = <String>[];
  late StateSetter update;

  AdaptiveSuperEditor scene(WidgetTester tester) =>
      tester.widget<AdaptiveSuperEditor>(find.byType(AdaptiveSuperEditor));

  Future<void> mount(WidgetTester tester) async {
    addTearDown(source.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return clipboard.future;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return BlockNoteEditor(
                pointerChrome: true,
                markdown: markdown,
                sourceMode: sourceMode,
                sourceController: source,
                readOnly: readOnly,
                onSourceModeChanged: (value) =>
                    update(() => sourceMode = value),
                onChanged: (value) {
                  changes.add(value);
                  update(() {
                    markdown = value;
                    if (source.text != value) source.text = value;
                  });
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> beginPaste(WidgetTester tester, {int start = 5}) async {
    final editor = scene(tester);
    editor.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: editor.document.first.id,
            nodePosition: TextNodePosition(offset: start),
          ),
          extent: DocumentPosition(
            nodeId: editor.document.first.id,
            nodePosition: const TextNodePosition(offset: 5),
          ),
        ),
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
    ]);
    editor.focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }
}
