import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/databases_controller.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:app/src/notes/folder_tree_sidebar.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required FolderTreeController controller,
  String? selectedPath,
  ValueChanged<String?>? onSelect,
  VoidCallback? onCreateFolder,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FolderTreeSidebar(
          controller: controller,
          selectedPath: selectedPath,
          onSelect: onSelect ?? (_) {},
          onCreateFolder: onCreateFolder ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('active note beyond the viewport is scrolled into view', (
    tester,
  ) async {
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    final controller = FolderTreeController(api: api);
    addTearDown(controller.dispose);
    controller.value = FolderTreeState(
      roots: const [
        FolderTreeNode(path: 'Projects', name: 'Projects', noteCount: 100),
      ],
      expandedPaths: const {'Projects'},
      contents: {
        '': const FolderContents(loaded: true),
        'Projects': FolderContents(
          loaded: true,
          notes: List.generate(
            100,
            (i) => NoteMeta(
              id: '$i',
              title: 'Note $i',
              path: 'Projects',
              version: 1,
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          ),
        ),
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FolderTreeSidebar(
            controller: controller,
            onSelect: (_) {},
            onCreateFolder: () {},
            selectedNoteId: '99',
            documentOpen: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('sidebar.note.99'));
    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, greaterThanOrEqualTo(0));
    expect(
      tester.getBottomLeft(row).dy,
      lessThanOrEqualTo(tester.view.physicalSize.height),
    );
  });

  group('FolderTreeSidebar', () {
    testWidgets(
      'renders folders from GET /notes/tree as an expandable tree with '
      'note counts',
      (tester) async {
        final mock = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'folders': <Object?>[
                {'path': '', 'note_count': 2},
                {'path': 'Projects/Alpha', 'note_count': 3},
                {'path': 'Projects/Beta', 'note_count': 1},
              ],
            }),
            200,
          );
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final controller = FolderTreeController(api: api);
        addTearDown(controller.dispose);

        await _pumpSidebar(tester, controller: controller);

        expect(find.text('All notes'), findsOneWidget);
        expect(find.text('Projects'), findsOneWidget);
        // Not yet expanded.
        expect(find.text('Alpha'), findsNothing);
        expect(find.text('Beta'), findsNothing);

        await tester.tap(find.byKey(const Key('sidebar.expand.Projects')));
        await tester.pumpAndSettle();

        expect(find.text('Alpha'), findsOneWidget);
        expect(find.text('Beta'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        expect(find.text('1'), findsOneWidget);
      },
    );

    testWidgets(
      'folder name selects without expanding and chevron leaves selection alone',
      (tester) async {
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'folders': [
                  {'path': 'Projects/Alpha', 'note_count': 1},
                ],
              }),
              200,
            ),
          ),
        );
        final controller = FolderTreeController(api: api);
        addTearDown(controller.dispose);
        String? selected;
        await _pumpSidebar(
          tester,
          controller: controller,
          onSelect: (p) => selected = p,
        );
        await tester.tap(find.text('Projects'));
        await tester.pumpAndSettle();
        expect(selected, 'Projects');
        expect(find.text('Alpha'), findsNothing);
        await tester.tap(find.byKey(const Key('sidebar.expand.Projects')));
        await tester.pumpAndSettle();
        expect(find.text('Alpha'), findsOneWidget);
        expect(selected, 'Projects');
      },
    );

    testWidgets('tapping "All notes" selects the null (unscoped) folder', (
      tester,
    ) async {
      final mock = MockClient((request) async {
        return http.Response(jsonEncode({'folders': <Object?>[]}), 200);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final controller = FolderTreeController(api: api);
      addTearDown(controller.dispose);
      String? selected = 'Projects/Alpha';

      await _pumpSidebar(
        tester,
        controller: controller,
        selectedPath: 'Projects/Alpha',
        onSelect: (p) => selected = p,
      );

      await tester.tap(find.text('All notes'));
      await tester.pumpAndSettle();

      expect(selected, isNull);
    });

    testWidgets('tapping a leaf folder selects its full path', (tester) async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'folders': <Object?>[
              {'path': 'Projects/Alpha', 'note_count': 3},
            ],
          }),
          200,
        );
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final controller = FolderTreeController(api: api);
      addTearDown(controller.dispose);
      String? selected;

      await _pumpSidebar(
        tester,
        controller: controller,
        onSelect: (p) => selected = p,
      );
      await tester.tap(find.byKey(const Key('sidebar.expand.Projects')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      expect(selected, 'Projects/Alpha');
    });

    testWidgets('tapping the header action invokes onCreateFolder', (
      tester,
    ) async {
      final mock = MockClient((request) async {
        return http.Response(jsonEncode({'folders': <Object?>[]}), 200);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final controller = FolderTreeController(api: api);
      addTearDown(controller.dispose);
      var tapped = false;

      await _pumpSidebar(
        tester,
        controller: controller,
        onCreateFolder: () => tapped = true,
      );
      await tester.tap(find.byKey(const Key('sidebar.newFolder')));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets(
      'a Databases section is hidden when databases is null and shown '
      'with entries and a New database action otherwise',
      (tester) async {
        final mock = MockClient((request) async {
          return http.Response(jsonEncode({'folders': <Object?>[]}), 200);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final controller = FolderTreeController(api: api);
        addTearDown(controller.dispose);

        await _pumpSidebar(tester, controller: controller);
        expect(find.text('Databases'), findsNothing);

        String? selectedId;
        var newTapped = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FolderTreeSidebar(
                controller: controller,
                onSelect: (_) {},
                onCreateFolder: () {},
                databases: const [
                  DatabaseSummary(
                    id: '01D',
                    title: 'Projects',
                    source: DatabaseSource.folder('Projects'),
                    rowCount: 3,
                  ),
                ],
                onSelectDatabase: (id) => selectedId = id,
                onNewDatabase: () => newTapped = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Databases'), findsOneWidget);
        expect(find.byKey(const Key('sidebar.database.01D')), findsOneWidget);
        expect(find.text('Projects'), findsOneWidget);

        await tester.tap(find.byKey(const Key('sidebar.database.01D')));
        expect(selectedId, '01D');

        await tester.tap(find.byKey(const Key('sidebar.newDatabase')));
        expect(newTapped, isTrue);
      },
    );

    testWidgets(
      'the Databases section stays current: it updates from the shared '
      'DatabasesController on a `changed` event without the sidebar being '
      'remounted (task 7.3)',
      (tester) async {
        final treeMock = MockClient((request) async {
          return http.Response(jsonEncode({'folders': <Object?>[]}), 200);
        });
        final treeApi = RobotNotesClient(config: _config, httpClient: treeMock);
        final tree = FolderTreeController(api: treeApi);
        addTearDown(tree.dispose);

        var call = 0;
        final dbMock = MockClient((request) async {
          call += 1;
          final title = call == 1 ? 'Projects' : 'Projects and Tasks';
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'id': '01D',
                  'title': title,
                  'path': '',
                  'source': <String, Object?>{
                    'folder': '',
                    'include_subfolders': true,
                  },
                  'row_count': 1,
                },
              ],
            }),
            200,
          );
        });
        final dbApi = RobotNotesClient(config: _config, httpClient: dbMock);
        final wsController = StreamController<RealtimeEvent>.broadcast();
        addTearDown(wsController.close);
        final databases = DatabasesController(
          api: dbApi,
          events: wsController.stream,
          // Synchronous in tests: the production 1 s debounce is exercised
          // in databases_controller_test.dart.
          debounceScheduler: (_) => Future<void>.value(),
        );
        addTearDown(databases.dispose);
        await databases.refresh();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<DatabasesState>(
                valueListenable: databases,
                builder: (context, state, _) => FolderTreeSidebar(
                  controller: tree,
                  onSelect: (_) {},
                  onCreateFolder: () {},
                  databases: state.items,
                  onSelectDatabase: (_) {},
                  onNewDatabase: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Projects'), findsOneWidget);
        expect(find.text('Projects and Tasks'), findsNothing);

        // A wildcard `changed` event (any note may be a database
        // definition) — see `DatabasesController`'s doc comment — triggers
        // the same debounced refresh the sidebar rides on.
        wsController.add(
          const RealtimeMessage(
            ChangedEvent(
              noteId: 'some-note',
              version: 2,
              by: 'cedric',
              action: ChangeAction.updated,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Projects and Tasks'), findsOneWidget);
        expect(find.text('Projects'), findsNothing);
      },
    );
  });
}
