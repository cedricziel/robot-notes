import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/folder_overview.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);
Map<String, Object> _note(String id, String title, String path) => {
  'id': id,
  'title': title,
  'path': path,
  'version': 1,
  'created_at': '2026-10-12T10:00:00Z',
  'updated_at': '2026-10-12T10:00:00Z',
};
FolderTreeController _controller(
  Future<http.Response> Function(http.Request) handler,
) {
  final api = RobotNotesClient(
    config: const AppConfig(
      baseUrl: 'https://notes.example',
      apiKey: 'key',
      actor: 'test',
    ),
    httpClient: MockClient(handler),
  );
  final controller = FolderTreeController(api: api);
  addTearDown(controller.dispose);
  addTearDown(api.close);
  return controller;
}

Future<void> _open(
  WidgetTester tester,
  FolderTreeController controller, {
  String path = 'Projects/Alpha',
  ValueChanged<String?>? onFolder,
  ValueChanged<String>? onNote,
  ValueChanged<VaultFile>? onFile,
  VoidCallback? onCreateNote,
  VoidCallback? onCreateFolder,
  VoidCallback? onUpload,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: FolderOverview(
        controller: controller,
        path: path,
        onSelectFolder: onFolder ?? (_) {},
        onSelectNote: onNote ?? (_) {},
        onSelectFile: onFile ?? (_) {},
        onCreateNote: onCreateNote ?? () {},
        onCreateFolder: onCreateFolder ?? () {},
        onUploadFile: onUpload ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'fresh folder overview loads child folders without opening a drawer',
    (tester) async {
      final controller = _controller((request) async {
        if (request.url.path == '/notes/tree') {
          return _json({
            'folders': [
              {'path': 'Projects/Alpha/Child', 'note_count': 1},
            ],
          });
        }
        return _json({'items': <Object?>[], 'limit': 50});
      });
      await _open(tester, controller);
      expect(find.text('Child'), findsOneWidget);
      expect(find.text('This folder is empty.'), findsNothing);
    },
  );

  testWidgets(
    'overview shows direct children and activates folders, notes and files',
    (tester) async {
      final requestedFolders = <String>[];
      final controller = _controller((request) async {
        if (request.url.path == '/notes/tree') {
          return _json({
            'folders': [
              {'path': 'Projects/Alpha/Child', 'note_count': 1},
              {'path': 'Projects/Beta', 'note_count': 1},
            ],
          });
        }
        requestedFolders.add(request.url.queryParameters['path']!);
        if (request.url.path == '/notes') {
          expect(request.url.queryParameters['include_subfolders'], 'false');
          return _json({
            'items': [_note('plan', 'Plan', 'Projects/Alpha')],
            'limit': 50,
          });
        }
        return _json({
          'items': [
            {
              'path': 'Projects/Alpha',
              'filename': 'diagram.png',
              'size': 10,
              'content_type': 'image/png',
              'updated_at': '2026-10-12T10:00:00Z',
            },
          ],
        });
      });
      await controller.refresh(refreshContents: false);
      String? folder;
      String? note;
      VaultFile? file;
      await _open(
        tester,
        controller,
        onFolder: (value) => folder = value,
        onNote: (value) => note = value,
        onFile: (value) => file = value,
      );

      expect(find.text('Child'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
      expect(requestedFolders, ['Projects/Alpha', 'Projects/Alpha']);
      expect(
        tester.getTopLeft(find.text('Child')).dy,
        lessThan(tester.getTopLeft(find.text('diagram.png')).dy),
      );
      await tester.tap(find.text('Child'));
      await tester.tap(find.text('Plan'));
      await tester.tap(find.text('diagram.png'));

      expect(folder, 'Projects/Alpha/Child');
      expect(note, 'plan');
      expect(file?.relativePath, 'Projects/Alpha/diagram.png');
    },
  );

  testWidgets('breadcrumbs navigate to ancestors, root and All notes', (
    tester,
  ) async {
    final controller = _controller(
      (_) async => _json({'items': <Object>[], 'limit': 50}),
    );
    final destinations = <String?>[];
    await _open(
      tester,
      controller,
      path: 'Projects/Alpha/Nested',
      onFolder: destinations.add,
    );

    await tester.tap(find.byKey(const Key('overview.breadcrumb.0')));
    await tester.tap(find.byKey(const Key('overview.breadcrumb.1')));
    await tester.tap(find.byKey(const Key('overview.root')));
    await tester.tap(find.byKey(const Key('overview.allNotes')));

    expect(destinations, ['Projects', 'Projects/Alpha', '', null]);
  });

  testWidgets('empty folders keep creation and upload actions available', (
    tester,
  ) async {
    final controller = _controller(
      (_) async => _json({'items': <Object>[], 'limit': 50}),
    );
    final actions = <String>[];
    await _open(
      tester,
      controller,
      onCreateNote: () => actions.add('note'),
      onCreateFolder: () => actions.add('folder'),
      onUpload: () => actions.add('upload'),
    );

    expect(find.text('This folder is empty.'), findsOneWidget);
    await tester.tap(find.byTooltip('New note'));
    await tester.tap(find.byTooltip('New folder'));
    await tester.tap(find.byTooltip('Upload file'));

    expect(actions, ['note', 'folder', 'upload']);
  });

  testWidgets('pending metadata shows loading instead of empty folder', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final controller = _controller(
      (request) async => request.url.path == '/notes'
          ? pending.future
          : _json({'items': <Object>[]}),
    );
    await _open(tester, controller);

    expect(find.text('Loading…'), findsOneWidget);
    expect(find.text('This folder is empty.'), findsNothing);
    pending.complete(_json({'items': <Object>[], 'limit': 50}));
    await tester.pumpAndSettle();
    expect(find.text('This folder is empty.'), findsOneWidget);
  });

  testWidgets('retry replaces a folder error with direct metadata', (
    tester,
  ) async {
    var failed = true;
    final controller = _controller((request) async {
      if (request.url.path != '/notes') return _json({'items': <Object>[]});
      return failed
          ? http.Response('', 503)
          : _json({
              'items': [_note('plan', 'Plan', 'Projects/Alpha')],
              'limit': 50,
            });
    });
    await _open(tester, controller);
    expect(find.text('Could not load contents. Retry'), findsOneWidget);
    failed = false;

    await tester.tap(find.text('Could not load contents. Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Could not load contents. Retry'), findsNothing);
  });

  testWidgets('load more retains earlier notes and sorts all loaded pages', (
    tester,
  ) async {
    final controller = _controller((request) async {
      if (request.url.path != '/notes') return _json({'items': <Object>[]});
      if (request.url.queryParameters['after'] == 'next') {
        return _json({
          'items': [_note('alpha', 'Alpha plan', 'Projects/Alpha')],
          'limit': 1,
        });
      }
      return _json({
        'items': [_note('zeta', 'Zeta plan', 'Projects/Alpha')],
        'limit': 1,
        'next_cursor': 'next',
      });
    });
    await _open(tester, controller);

    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();

    expect(find.text('Zeta plan'), findsOneWidget);
    expect(find.text('Alpha plan'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Alpha plan')).dy,
      lessThan(tester.getTopLeft(find.text('Zeta plan')).dy),
    );
    expect(find.text('Load more'), findsNothing);
  });
}
