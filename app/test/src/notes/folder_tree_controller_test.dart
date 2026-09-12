import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

http.Response _treeResponse(List<Map<String, Object?>> folders) =>
    http.Response(jsonEncode(<String, Object?>{'folders': folders}), 200);

void main() {
  group('buildFolderTree', () {
    test('nests folders under their intermediate segments', () {
      final nodes = buildFolderTree(const [
        TreeFolder(path: 'Projects/Alpha', noteCount: 3),
        TreeFolder(path: 'Projects/Beta', noteCount: 1),
      ]);

      expect(nodes, hasLength(1));
      final projects = nodes.single;
      expect(projects.name, 'Projects');
      expect(projects.path, 'Projects');
      expect(projects.children.map((n) => n.name), <String>['Alpha', 'Beta']);
      expect(projects.children[0].path, 'Projects/Alpha');
      expect(projects.children[0].noteCount, 3);
      expect(projects.children[1].noteCount, 1);
    });

    test('ignores the root ("") entry, which is not a nested node', () {
      final nodes = buildFolderTree(const [
        TreeFolder(path: '', noteCount: 5),
        TreeFolder(path: 'Notes', noteCount: 2),
      ]);

      expect(nodes.map((n) => n.path), <String>['Notes']);
    });

    test('deeper nesting builds multiple levels', () {
      final nodes = buildFolderTree(const [
        TreeFolder(path: 'A/B/C', noteCount: 1),
      ]);

      final a = nodes.single;
      expect(a.path, 'A');
      final b = a.children.single;
      expect(b.path, 'A/B');
      final c = b.children.single;
      expect(c.path, 'A/B/C');
      expect(c.noteCount, 1);
    });
  });

  group('FolderTreeController', () {
    test('refresh fetches the tree and exposes nested nodes', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/notes/tree');
        return _treeResponse([
          {'path': '', 'note_count': 2},
          {'path': 'Projects/Alpha', 'note_count': 3},
          {'path': 'Projects/Beta', 'note_count': 1},
        ]);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = FolderTreeController(api: api);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();

      expect(ctrl.value.rootNoteCount, 2);
      expect(ctrl.value.roots.single.name, 'Projects');
      expect(ctrl.value.isLoading, isFalse);
      expect(ctrl.value.error, isNull);
    });

    for (final action in [
      ChangeAction.moved,
      ChangeAction.created,
      ChangeAction.deleted,
    ]) {
      test('changed{${action.wire}} triggers a tree re-fetch', () async {
        var calls = 0;
        final mock = MockClient((request) async {
          calls += 1;
          return _treeResponse([
            {'path': 'Notes', 'note_count': calls},
          ]);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final events = StreamController<RealtimeEvent>.broadcast();
        addTearDown(events.close);
        final ctrl = FolderTreeController(api: api, events: events.stream);
        addTearDown(ctrl.dispose);

        await ctrl.refresh();
        expect(calls, 1);

        events.add(
          RealtimeMessage(
            ChangedEvent(
              noteId: '01H',
              version: 2,
              by: 'alice',
              action: action,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(calls, 2);
      });
    }

    test('changed{updated} does not trigger a tree re-fetch', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls += 1;
        return _treeResponse(const []);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final events = StreamController<RealtimeEvent>.broadcast();
      addTearDown(events.close);
      final ctrl = FolderTreeController(api: api, events: events.stream);
      addTearDown(ctrl.dispose);

      await ctrl.refresh();
      expect(calls, 1);

      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01H',
            version: 2,
            by: 'alice',
            action: ChangeAction.updated,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
    });
  });
}
