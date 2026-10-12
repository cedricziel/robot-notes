import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:app/src/notes/folder_tree_sidebar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

FolderTreeController _controller({List<String>? requestedFolders}) {
  final api = RobotNotesClient(
    config: const AppConfig(
      baseUrl: 'https://notes.example',
      apiKey: 'key',
      actor: 'test',
    ),
    httpClient: MockClient((request) async {
      if (request.url.path == '/notes/tree') {
        return http.Response(
          jsonEncode({
            'folders': [
              {'path': 'Projects/Alpha', 'note_count': 0},
              {'path': 'Other', 'note_count': 0},
            ],
          }),
          200,
        );
      }
      requestedFolders?.add(request.url.queryParameters['path']!);
      return http.Response('{"items":[],"limit":50}', 200);
    }),
  );
  final controller = FolderTreeController(api: api);
  addTearDown(controller.dispose);
  addTearDown(api.close);
  return controller;
}

Future<void> _open(
  WidgetTester tester,
  FolderTreeController controller, {
  ValueChanged<String?>? onSelect,
  String? selectedPath,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: FolderTreeSidebar(
          controller: controller,
          selectedPath: selectedPath,
          onSelect: onSelect ?? (_) {},
          onCreateFolder: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _focusRow(WidgetTester tester, String id) =>
    Focus.of(tester.element(find.byKey(Key('sidebar.$id')))).requestFocus();

void main() {
  testWidgets('right and left expand and collapse without selecting a folder', (
    tester,
  ) async {
    final requestedFolders = <String>[];
    final controller = _controller(requestedFolders: requestedFolders);
    final selected = <String?>[];
    await _open(tester, controller, onSelect: selected.add);
    expect(requestedFolders, ['', '']);
    _focusRow(tester, 'folder.Projects');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(selected, isEmpty);
    expect(requestedFolders, ['', '', 'Projects', 'Projects']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);
    expect(selected, isEmpty);
  });

  testWidgets('Enter selects a folder without expanding it', (tester) async {
    final controller = _controller();
    final selected = <String?>[];
    await _open(tester, controller, onSelect: selected.add);
    _focusRow(tester, 'folder.Projects');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(selected, ['Projects']);
    expect(find.text('Alpha'), findsNothing);
  });

  testWidgets('Down and Up move one visible row before Enter activation', (
    tester,
  ) async {
    final controller = _controller();
    final selected = <String?>[];
    await _open(tester, controller, onSelect: selected.add);
    _focusRow(tester, 'allNotes');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, ['']);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, ['', null]);
  });

  testWidgets('folder semantics expose selected and expanded states', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final controller = _controller();
    await _open(tester, controller, selectedPath: 'Projects');
    final folderSemantics = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.expanded != null &&
          widget.properties.selected == true,
    );

    var flags = tester
        .getSemantics(folderSemantics)
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isSelected, Tristate.isTrue);
    expect(flags.isExpanded, Tristate.isFalse);
    await tester.tap(find.byKey(const Key('sidebar.expand.Projects')));
    await tester.pumpAndSettle();
    flags = tester
        .getSemantics(folderSemantics)
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isSelected, Tristate.isTrue);
    expect(flags.isExpanded, Tristate.isTrue);
    semantics.dispose();
  });
}
