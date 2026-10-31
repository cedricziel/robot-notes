import 'package:adaptive_super_editor/adaptive_super_editor.dart';
import 'package:cupertino_ui/cupertino_ui.dart' as cupertino;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_editor/super_editor.dart';

import 'package:app/src/notes/block_note_editor.dart';
import 'package:app/src/theme/app_theme.dart';

void main() {
  testWidgets('blocks show no mode selector and source offers Back to Blocks', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'Draft',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('block-mode-selector')), findsNothing);
    expect(find.text('Markdown source'), findsNothing);
    expect(find.text('Back to Blocks'), findsNothing);
    final editor = tester
        .widget<AdaptiveSuperEditor>(find.byType(AdaptiveSuperEditor))
        .editor;
    await _showSource(tester);
    expect(find.text('Back to Blocks'), findsOneWidget);
    await tester.tap(find.text('Back to Blocks'));
    await tester.pumpAndSettle();
    expect(find.text('Back to Blocks'), findsNothing);
    expect(
      identical(
        tester
            .widget<AdaptiveSuperEditor>(find.byType(AdaptiveSuperEditor))
            .editor,
        editor,
      ),
      isTrue,
    );
    expect(changes, isEmpty);
  });

  testWidgets('task checkbox begins at the paragraph content edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'Paragraph\n\n- [ ] Task',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(legacy.Checkbox)).dx,
      closeTo(tester.getTopLeft(find.byType(ParagraphComponent)).dx, 0.1),
    );
    final checkbox = tester.getRect(find.byType(legacy.Checkbox));
    expect(checkbox.width, 18);
    final taskText = find.byType(TextComponent).last;
    final component = tester.state(taskText) as DocumentComponent;
    final firstLine = component.getRectForPosition(
      const TextNodePosition(offset: 0),
    );
    expect(
      checkbox.center.dy,
      closeTo(tester.getTopLeft(taskText).dy + firstLine.center.dy, 2),
    );
    await tester.tapAt(
      tester.getTopLeft(taskText) + Offset(12, firstLine.center.dy),
    );
    await tester.pump();
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
    expect(scene.composer.selection!.extent.nodeId, scene.document.last.id);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
    'blocks share a full-width gutter and handles follow first lines',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'Paragraph\n\n# Heading\n\n```dart\nprint(1);\n```\n\n| A |\n| - |\n| B |',
              onChanged: (_) {},
              opaqueBuilder: (_, source) => const SizedBox(height: 60),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final handles = find.byIcon(Icons.drag_indicator);
      expect(handles, findsNWidgets(4));
      final lefts = [
        for (var i = 0; i < 4; i++) tester.getCenter(handles.at(i)).dx,
      ];
      expect(lefts[1], closeTo(lefts[0], 0.1));
      expect(lefts[2], closeTo(lefts[0], 0.1));
      expect(lefts[3], closeTo(lefts[0], 0.1));
      final paragraphs = find.byType(ParagraphComponent);
      expect(tester.getSize(paragraphs.first).width, greaterThan(1000));
      final styles = AppTheme.markdown(
        tester.element(find.byType(BlockNoteEditor)),
      );
      expect(
        tester
            .widget<ParagraphComponent>(paragraphs.at(1))
            .viewModel
            .textStyleBuilder({})
            .fontSize,
        styles.h1!.fontSize,
      );
      expect(
        tester
            .widget<ParagraphComponent>(paragraphs.first)
            .viewModel
            .textStyleBuilder({})
            .height,
        styles.p!.height,
      );
      for (var i = 0; i < 3; i++) {
        final component = tester.state(paragraphs.at(i)) as DocumentComponent;
        final firstLine = component.getRectForPosition(
          const TextNodePosition(offset: 0),
        );
        final lineCenter =
            tester.getTopLeft(paragraphs.at(i)).dy + firstLine.center.dy;
        expect(tester.getCenter(handles.at(i)).dy, closeTo(lineCenter, 2));
      }
    },
  );

  testWidgets('switching presentations preserves exact source without edits', (
    tester,
  ) async {
    const source = '# Heading\r\n\r\n| A |\r\n| - |\r\n| B |\r\n';
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: source,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await _showSource(tester);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('block-source')))
          .controller!
          .text,
      source,
    );
    await tester.tap(find.text('Back to Blocks'));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(find.byType(AdaptiveSuperEditor), findsOneWidget);
  });

  testWidgets(
    'deleting the final block leaves an empty paragraph and undo restores it',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'Last',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Block actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete block'));
      await tester.pumpAndSettle();
      expect(changes.last, '');
      final editor = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      expect(editor.document.first, isA<ParagraphNode>());
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(changes.last, 'Last');
    },
  );

  testWidgets(
    'conversion retains text and move actions retain block identity',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'First\n\nSecond',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final editor = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      final lastId = editor.document.last.id;
      await tester.tap(find.byTooltip('Block actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Convert block'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heading 2'));
      await tester.pumpAndSettle();
      expect(changes.last, 'First\n\n## Second');
      await tester.tap(find.byTooltip('Block actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      expect(editor.document.first.id, lastId);
      expect(changes.last, '## Second\n\nFirst');
    },
  );

  testWidgets('source edits use the same document and remain undoable', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'Before',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final editor = tester
        .widget<AdaptiveSuperEditor>(find.byType(AdaptiveSuperEditor))
        .editor;
    await _showSource(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('block-source')),
      '# After',
    );
    await tester.tap(find.text('Back to Blocks'));
    await tester.pumpAndSettle();
    expect(
      identical(
        tester
            .widget<AdaptiveSuperEditor>(find.byType(AdaptiveSuperEditor))
            .editor,
        editor,
      ),
      isTrue,
    );
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    expect(changes.last, 'Before');
  });

  testWidgets('read only hides mutations and source remains read only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: '- [ ] Task',
            readOnly: true,
            onChanged: (_) => fail('mutated'),
          ),
        ),
      ),
    );
    expect(find.byTooltip('Block actions'), findsNothing);
    expect(find.byTooltip('Bold'), findsNothing);
    await _showSource(tester);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('block-source')))
          .readOnly,
      isTrue,
    );
  });
  testWidgets(
    'paragraph Enter and Backspace split and merge through one document',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'FirstSecond',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      scene.editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: scene.document.first.id,
              nodePosition: const TextNodePosition(offset: 5),
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
        InsertNewlineAtCaretRequest(),
      ]);
      await tester.pump();
      expect(changes.last, 'First\n\nSecond');
      scene.focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(changes.last, 'FirstSecond');
    },
  );

  testWidgets('list Enter continues then exits an empty item', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: '- Item',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
    scene.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: scene.document.first.id,
            nodePosition: const TextNodePosition(offset: 4),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
      InsertNewlineAtCaretRequest(),
    ]);
    expect(scene.document.last, isA<ListItemNode>());
    scene.editor.execute([InsertNewlineAtCaretRequest()]);
    await tester.pump();
    expect(scene.document.last, isA<ParagraphNode>());
    expect((scene.document.last as TextNode).text.toPlainText(), '');
  });

  testWidgets('code Enter inserts a literal newline', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: '\x60\x60\x60dart\nline\n\x60\x60\x60',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
    scene.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: scene.document.first.id,
            nodePosition: const TextNodePosition(offset: 4),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
      InsertNewlineAtCaretRequest(),
    ]);
    await tester.pump();
    expect(scene.document.nodeCount, 1);
    expect(changes.last, '\x60\x60\x60dart\nline\n\n\x60\x60\x60');
  });

  testWidgets(
    'formatting controls keep selection and undo restores plain text',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'First second',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      scene.editor.execute([
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition(
              nodeId: scene.document.first.id,
              nodePosition: const TextNodePosition(offset: 0),
            ),
            extent: DocumentPosition(
              nodeId: scene.document.first.id,
              nodePosition: const TextNodePosition(offset: 5),
            ),
          ),
          SelectionChangeType.expandSelection,
          SelectionReason.userInteraction,
        ),
      ]);
      scene.focusNode.requestFocus();
      await tester.pump();
      await tester.tap(find.byTooltip('Bold'));
      await tester.pump();
      expect(changes.last, '**First** second');
      expect(scene.composer.selection!.isCollapsed, isFalse);
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(changes.last, 'First second');
      await tester.tap(find.byTooltip('Redo'));
      await tester.pump();
      expect(changes.last, '**First** second');
    },
  );

  testWidgets(
    'slash insertion removes command text and Escape dismisses first',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: '',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
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
        const InsertPlainTextAtCaretRequest('/'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Convert block'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Convert block'), findsNothing);
      expect(changes.last, '/');
      await tester.tap(find.byTooltip('Block actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Convert block'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heading 1'));
      await tester.pumpAndSettle();
      expect(changes.last, '# /');
    },
  );

  testWidgets('divider conversion requires an explicit destructive action', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'Keep text',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Block actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Convert block'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Divider'));
    await tester.tap(find.text('Divider'));
    await tester.pumpAndSettle();
    expect(find.text('Replace text with divider?'), findsOneWidget);
    expect(changes, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
  });

  testWidgets('Markdown paste keeps an unsupported table verbatim', (
    tester,
  ) async {
    const table = '| A | B |\r\n| - | - |\r\n| one | two |';
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: '',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
    final position = DocumentPosition(
      nodeId: scene.document.first.id,
      nodePosition: const TextNodePosition(offset: 0),
    );
    scene.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection.collapsed(position: position),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
      PasteEditorRequest(content: table, pastePosition: position),
    ]);
    await tester.pump();
    expect(changes.last, contains(table));
    expect(
      scene.document.toList().whereType<OpaqueMarkdownNode>(),
      hasLength(1),
    );
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(changes.last, '');
    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();
    expect(changes.last, contains(table));
  });

  testWidgets(
    'matching save acknowledgement retains document selection and composition',
    (tester) async {
      var markdown = 'Before';
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return BlockNoteEditor(
                  pointerChrome: true,
                  markdown: markdown,
                  onChanged: (value) => markdown = value,
                );
              },
            ),
          ),
        ),
      );
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      final id = scene.document.first.id;
      final selection = DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: id,
          nodePosition: const TextNodePosition(offset: 6),
        ),
      );
      scene.editor.execute([
        ChangeSelectionRequest(
          selection,
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
        const InsertPlainTextAtCaretRequest(' typing'),
        ChangeComposingRegionRequest(
          DocumentRange(
            start: DocumentPosition(
              nodeId: id,
              nodePosition: const TextNodePosition(offset: 6),
            ),
            end: DocumentPosition(
              nodeId: id,
              nodePosition: const TextNodePosition(offset: 13),
            ),
          ),
        ),
      ]);
      final composition = scene.composer.composingRegion;
      rebuild(() {});
      await tester.pump();
      final updated = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      expect(identical(updated.editor, scene.editor), isTrue);
      expect(updated.composer.selection, scene.composer.selection);
      expect(updated.composer.composingRegion, composition);
      expect(updated.document.first.id, id);
    },
  );

  testWidgets(
    'choosing a slash heading removes the command and keeps typing there',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: '',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
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
        const InsertPlainTextAtCaretRequest('/'),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heading 2'));
      await tester.pumpAndSettle();
      scene.editor.execute([const InsertPlainTextAtCaretRequest('Title')]);
      await tester.pump();
      expect(changes.last, '## Title');
      expect(scene.focusNode.hasFocus, isTrue);
    },
  );

  testWidgets('labelled insertion works without a selection', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'Existing',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Insert block'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heading 3'));
    await tester.pumpAndSettle();
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
    scene.editor.execute([const InsertPlainTextAtCaretRequest('New')]);
    await tester.pump();
    expect(changes.last, 'Existing\n\n### New');
  });

  testWidgets('opaque source action selects its exact range', (tester) async {
    const source = 'Paragraph\n\n| A |\n| - |\n| B |';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: source,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Block actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Markdown source'));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TextField>(find.byKey(const ValueKey('block-source')))
        .controller!;
    expect(
      controller.selection.textInside(controller.text),
      '| A |\n| - |\n| B |',
    );
  });

  testWidgets('link dialogue applies a destination to the retained selection', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'A title',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
    scene.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: scene.document.first.id,
            nodePosition: const TextNodePosition(offset: 2),
          ),
          extent: DocumentPosition(
            nodeId: scene.document.first.id,
            nodePosition: const TextNodePosition(offset: 7),
          ),
        ),
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
    ]);
    scene.focusNode.requestFocus();
    await tester.pump();
    await tester.tap(find.byTooltip('Add link'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'https://example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Add link'));
    await tester.pumpAndSettle();
    expect(changes.last, 'A [title](https://example.com)');
    expect(scene.composer.selection!.isCollapsed, isFalse);
  });

  testWidgets('wiki link completion retains literal Markdown syntax', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: '',
            onChanged: changes.add,
            searchLinkTitles: (_) async => ['Another note'],
          ),
        ),
      ),
    );
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
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
      const InsertPlainTextAtCaretRequest('[[Another'),
    ]);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.tap(find.text('Another note'));
    await tester.pump();
    expect(changes.last, '[[Another note]]');
  });

  testWidgets('scaled narrow desktop insertion dialogue remains scrollable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 600),
            textScaler: TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'Text',
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Insert block'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Divider'));
    await tester.tap(find.text('Divider'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'task checkbox changes the Markdown draft and has a readable label',
    (tester) async {
      final handle = tester.ensureSemantics();
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: '- [ ] Buy milk',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel('Checkbox: Buy milk'), findsOneWidget);
      await tester.tap(find.byType(legacy.Checkbox));
      await tester.pump();
      handle.dispose();
      expect(changes.last, '- [x] Buy milk');
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(changes.last, '- [ ] Buy milk');
    },
  );

  testWidgets('drag handle reorders while retaining selection and undo', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'First\n\nSecond',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
    final id = scene.document.last.id;
    final selection = DocumentSelection.collapsed(
      position: DocumentPosition(
        nodeId: id,
        nodePosition: const TextNodePosition(offset: 3),
      ),
    );
    scene.editor.execute([
      ChangeSelectionRequest(
        selection,
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
    scene.focusNode.requestFocus();
    await tester.pump();
    await tester.dragFrom(
      tester.getCenter(find.byIcon(Icons.drag_indicator).last),
      tester.getCenter(find.byIcon(Icons.drag_indicator).first) -
          tester.getCenter(find.byIcon(Icons.drag_indicator).last),
    );
    await tester.pumpAndSettle();
    expect(changes.last, 'Second\n\nFirst');
    expect(scene.composer.selection, selection);
    expect(scene.document.first.id, id);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(changes.last, 'First\n\nSecond');
  });

  testWidgets(
    'platform formatting and undo shortcuts reach the selected document',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'word',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      scene.editor.execute([
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition(
              nodeId: scene.document.first.id,
              nodePosition: const TextNodePosition(offset: 0),
            ),
            extent: DocumentPosition(
              nodeId: scene.document.first.id,
              nodePosition: const TextNodePosition(offset: 4),
            ),
          ),
          SelectionChangeType.expandSelection,
          SelectionReason.userInteraction,
        ),
      ]);
      scene.focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(changes.last, '**word**');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(changes.last, 'word');
    },
  );

  testWidgets(
    'source builder owns its controller and receives no duplicate header',
    (tester) async {
      final controller = TextEditingController(text: 'Body');
      var markdown = 'Body';
      var sourceMode = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return BlockNoteEditor(
                  pointerChrome: true,
                  markdown: markdown,
                  sourceMode: sourceMode,
                  onSourceModeChanged: (value) =>
                      setState(() => sourceMode = value),
                  onChanged: (value) => markdown = value,
                  sourceController: controller,
                  header: const Text('Block title'),
                  sourceBuilder: (context, source, readOnly) => TextField(
                    controller: source,
                    readOnly: readOnly,
                    onChanged: (value) => setState(() => markdown = value),
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('Block title'), findsOneWidget);
      await _showSource(tester);
      await tester.pumpAndSettle();
      expect(find.text('Block title'), findsNothing);
      await tester.enterText(find.byType(TextField), '# New body');
      await tester.tap(find.text('Back to Blocks'));
      await tester.pumpAndSettle();
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      expect((scene.document.first as TextNode).text.toPlainText(), 'New body');
      await tester.pumpWidget(const SizedBox());
      controller.text = 'Still owned';
      controller.dispose();
    },
  );

  testWidgets(
    'native multiblock copy and deletion preserve the unselected text',
    (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'First\n\nSecond',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      scene.editor.execute([
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition(
              nodeId: scene.document.first.id,
              nodePosition: const TextNodePosition(offset: 2),
            ),
            extent: DocumentPosition(
              nodeId: scene.document.last.id,
              nodePosition: const TextNodePosition(offset: 3),
            ),
          ),
          SelectionChangeType.expandSelection,
          SelectionReason.userInteraction,
        ),
      ]);
      scene.focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(clipboard, 'rst\nSec');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(changes.last, 'Fiond');
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(changes.last, 'First\n\nSecond');
    },
  );
  testWidgets(
    'returning from edited source maps its caret to the corresponding paragraph',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'First\n\nSecond',
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await _showSource(tester);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('block-source')),
        'First\n\nChanged',
      );
      final controller = tester
          .widget<TextField>(find.byKey(const ValueKey('block-source')))
          .controller!;
      controller.selection = const TextSelection.collapsed(offset: 10);
      await tester.tap(find.text('Back to Blocks'));
      await tester.pumpAndSettle();
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      expect(scene.composer.selection!.extent.nodeId, scene.document.last.id);
      expect(
        scene.composer.selection!.extent.nodePosition,
        const TextNodePosition(offset: 3),
      );
    },
  );

  testWidgets('native plain text paste replaces a multiblock selection', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': 'Replacement'} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'First\n\nSecond',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
    scene.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: scene.document.first.id,
            nodePosition: const TextNodePosition(offset: 2),
          ),
          extent: DocumentPosition(
            nodeId: scene.document.last.id,
            nodePosition: const TextNodePosition(offset: 3),
          ),
        ),
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
    ]);
    scene.focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(changes.last, 'FiReplacementond');
  });
  testWidgets(
    'read only task checkbox cannot mutate through keyboard activation',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: '- [ ] Task',
              readOnly: true,
              onChanged: (_) => fail('mutated'),
            ),
          ),
        ),
      );
      expect(
        tester.widget<legacy.Checkbox>(find.byType(legacy.Checkbox)).onChanged,
        isNull,
      );
    },
  );
  testWidgets('Apple block menu uses the shared touch action sheet', (
    tester,
  ) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'First\n\nSecond',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Block actions').first);
    await tester.pumpAndSettle();
    expect(find.byType(cupertino.CupertinoActionSheet), findsOneWidget);
    await tester.tap(find.text('Move down'));
    await tester.pumpAndSettle();
    expect(changes.last, 'Second\n\nFirst');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inline code action formats selected text without changing adjacent words',
    (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: true,
              markdown: 'A word',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      scene.editor.execute([
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition(
              nodeId: scene.document.first.id,
              nodePosition: const TextNodePosition(offset: 2),
            ),
            extent: DocumentPosition(
              nodeId: scene.document.first.id,
              nodePosition: const TextNodePosition(offset: 6),
            ),
          ),
          SelectionChangeType.expandSelection,
          SelectionReason.userInteraction,
        ),
      ]);
      await tester.tap(find.byTooltip('Inline code'));
      await tester.pump();
      expect(changes.last, 'A \x60word\x60');
    },
  );

  testWidgets('a literal slash in code does not open paragraph insertion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: '\x60\x60\x60\n\n\x60\x60\x60',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final scene = tester.widget<AdaptiveSuperEditor>(
      find.byType(AdaptiveSuperEditor),
    );
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
      const InsertPlainTextAtCaretRequest('/'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Convert block'), findsNothing);
  });

  group('touch layout', () {
    testWidgets('blocks get no handles, menus, or side gutters', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: false,
              markdown: '# Heading\n\n- One\n- Two',
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      // Only the toolbar's menu, none beside the blocks.
      expect(find.byTooltip('Block actions'), findsOneWidget);
      final editor = tester.getRect(find.byType(AdaptiveSuperEditor));
      final heading = tester.getRect(find.byType(TextComponent).first);
      expect(heading.left, closeTo(editor.left, 0.1));
      expect(heading.right, closeTo(editor.right, 0.1));
    });

    testWidgets('toolbar block actions act on the block under the caret', (
      tester,
    ) async {
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockNoteEditor(
              pointerChrome: false,
              markdown: 'First\n\nSecond',
              onChanged: changes.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scene = tester.widget<AdaptiveSuperEditor>(
        find.byType(AdaptiveSuperEditor),
      );
      final second = scene.document.getNodeAt(1)!;
      scene.editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: second.id,
              nodePosition: const TextNodePosition(offset: 0),
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Block actions'));
      await tester.pumpAndSettle();
      expect(find.text('Move down'), findsNothing);
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      expect(changes.last, 'Second\n\nFirst');
    });
  });

  testWidgets('pointer chrome stays hidden until a block is hovered', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockNoteEditor(
            pointerChrome: true,
            markdown: 'First\n\nSecond',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double opacityOf(Finder icon) => tester
        .widget<AnimatedOpacity>(
          find.ancestor(of: icon, matching: find.byType(AnimatedOpacity)).first,
        )
        .opacity;
    final handles = find.byIcon(Icons.drag_indicator);
    expect(opacityOf(handles.first), 0);
    expect(opacityOf(handles.last), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(TextComponent).last));
    await tester.pumpAndSettle();
    expect(opacityOf(handles.first), 0);
    expect(opacityOf(handles.last), 1);
  });
}

Future<void> _showSource(WidgetTester tester) async {
  final finder = find.byType(BlockNoteEditor);
  final widget = tester.widget<BlockNoteEditor>(finder);
  if (widget.onSourceModeChanged != null) {
    widget.onSourceModeChanged!(true);
    await tester.pumpAndSettle();
    return;
  }
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BlockNoteEditor(
          pointerChrome: true,
          key: widget.key,
          markdown: widget.markdown,
          onChanged: widget.onChanged,
          sourceMode: true,
          onSourceModeChanged: widget.onSourceModeChanged,
          readOnly: widget.readOnly,
          sourceController: widget.sourceController,
          header: widget.header,
          sourceBuilder: widget.sourceBuilder,
          opaqueBuilder: widget.opaqueBuilder,
          searchLinkTitles: widget.searchLinkTitles,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
