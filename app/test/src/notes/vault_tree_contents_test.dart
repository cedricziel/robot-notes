import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:shared/shared.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'key',
  actor: 'tester',
);
Map<String, Object?> note(String id, String path) => {
  'id': id,
  'title': id,
  'path': path,
  'version': 1,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};
http.Response response(Object body) => http.Response(jsonEncode(body), 200);
void main() {
  test(
    'live moves refresh hierarchy and both loaded folders without duplicates',
    () async {
      var folder = 'Old';
      final api = RobotNotesClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/notes/tree') {
            return response({
              'folders': [
                {'path': folder, 'note_count': 1},
              ],
            });
          }
          if (request.url.path == '/notes/files') {
            return response({'items': <Object?>[]});
          }
          return response({
            'items': request.url.queryParameters['path'] == folder
                ? [note('A', folder)]
                : <Object?>[],
            'limit': 50,
          });
        }),
      );
      final events = StreamController<RealtimeEvent>.broadcast();
      addTearDown(events.close);
      final tree = FolderTreeController(api: api, events: events.stream);
      addTearDown(tree.dispose);
      await tree.refresh();
      await tree.expand('Old');
      await tree.expand('New');
      final updated = Completer<void>();
      tree.addListener(() {
        if (!updated.isCompleted &&
            tree.value.contents['New']!.notes.isNotEmpty &&
            tree.value.contents['Old']!.notes.isEmpty) {
          updated.complete();
        }
      });
      folder = 'New';
      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: 'A',
            version: 2,
            by: 'other',
            action: ChangeAction.moved,
          ),
        ),
      );
      await updated.future;
      expect(tree.value.roots.single.path, 'New');
      expect(tree.value.contents['New']!.notes.single.id, 'A');
      expect(tree.value.contents['Old']!.notes, isEmpty);
    },
  );

  test('superseded reveal stops before expanding stale descendants', () async {
    final pending = Completer<http.Response>();
    final api = RobotNotesClient(
      config: config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/notes/files') {
          return response({'items': <Object?>[]});
        }
        if (request.url.queryParameters['path'] == 'Old') return pending.future;
        return response({'items': <Object?>[], 'limit': 50});
      }),
    );
    final tree = FolderTreeController(api: api);
    addTearDown(tree.dispose);
    final old = tree.revealNote('A', 'Old/Child');
    tree.cancelReveal();
    await tree.revealFile('New');
    pending.complete(response({'items': <Object?>[], 'limit': 50}));
    await old;
    expect(tree.value.expandedPaths, isNot(contains('Old/Child')));
    expect(tree.value.expandedPaths, contains('New'));
  });

  test(
    'expansion loads direct contents and retains pages across collapse',
    () async {
      final paths = <String>[];
      final api = RobotNotesClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/notes/files') {
            return response({
              'items': [
                {
                  'path': 'Projects',
                  'filename': 'diagram.png',
                  'size': 4,
                  'content_type': 'image/png',
                  'updated_at': '2026-01-01T00:00:00Z',
                },
              ],
            });
          }
          paths.add(request.url.queryParameters['path']!);
          expect(request.url.queryParameters['include_subfolders'], 'false');
          return response({
            'items': [
              note(
                request.url.queryParameters.containsKey('after') ? 'B' : 'A',
                'Projects',
              ),
            ],
            'limit': 50,
            'next_cursor': request.url.queryParameters.containsKey('after')
                ? null
                : 'A',
          });
        }),
      );
      final tree = FolderTreeController(api: api);
      addTearDown(tree.dispose);
      await tree.expand('Projects');
      expect(tree.value.contents['Projects']!.notes.single.id, 'A');
      expect(
        tree.value.contents['Projects']!.files.single.filename,
        'diagram.png',
      );
      await tree.loadMore('Projects');
      tree.collapse('Projects');
      await tree.expand('Projects');
      expect(tree.value.contents['Projects']!.notes.map((n) => n.id), [
        'A',
        'B',
      ]);
      expect(paths, ['Projects', 'Projects']);
    },
  );
  test('failed folder can retry without discarding another folder', () async {
    var fail = true;
    final api = RobotNotesClient(
      config: config,
      httpClient: MockClient((request) async {
        final path = request.url.queryParameters['path'];
        if (path == 'B' && fail) return http.Response('unavailable', 500);
        return response({
          'items': request.url.path == '/notes/files'
              ? <Object?>[]
              : [note(path!, path)],
          'limit': 50,
        });
      }),
    );
    final tree = FolderTreeController(api: api);
    addTearDown(tree.dispose);
    await tree.expand('A');
    await tree.expand('B');
    expect(tree.value.contents['B']!.error, isNotNull);
    expect(tree.value.contents['A']!.notes.single.id, 'A');
    fail = false;
    await tree.loadFolder('B', force: true);
    expect(tree.value.contents['B']!.error, isNull);
    expect(tree.value.contents['B']!.notes.single.id, 'B');
  });
  test('disposed session ignores delayed folder responses', () async {
    final pending = Completer<http.Response>();
    final api = RobotNotesClient(
      config: config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/notes/files') {
          return response({'items': <Object?>[]});
        }
        return pending.future;
      }),
    );
    final tree = FolderTreeController(api: api);
    final loading = tree.expand('A');
    tree.dispose();
    pending.complete(
      response({
        'items': [note('A', 'A')],
        'limit': 50,
      }),
    );
    await loading;
    expect(tree.value.contents['A']!.notes, isEmpty);
  });
  test(
    'revealing later-page note expands ancestors and loads its page',
    () async {
      final api = RobotNotesClient(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/notes/files') {
            return response({'items': <Object?>[]});
          }
          final path = request.url.queryParameters['path']!;
          final more = request.url.queryParameters.containsKey('after');
          return response({
            'items': path == 'A/B'
                ? [note(more ? 'target' : 'first', path)]
                : <Object?>[],
            'limit': 50,
            'next_cursor': path == 'A/B' && !more ? 'first' : null,
          });
        }),
      );
      final tree = FolderTreeController(api: api);
      addTearDown(tree.dispose);
      await tree.revealNote('target', 'A/B');
      expect(tree.value.expandedPaths, containsAll(['A', 'A/B']));
      expect(tree.value.contents['A/B']!.notes.last.id, 'target');
    },
  );
}
