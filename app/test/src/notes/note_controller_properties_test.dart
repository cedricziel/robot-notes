import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/note_controller.dart';
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

const _now = '2025-01-01T00:00:00.000Z';

Map<String, Object?> _noteJson({
  String id = '01H',
  String title = 'hello',
  String content = 'world',
  String path = 'Projects',
  int version = 1,
  Map<String, Object?>? lock,
  Map<String, Object?> properties = const {},
  List<String> tags = const [],
}) => <String, Object?>{
  'id': id,
  'title': title,
  'path': path,
  'content': content,
  'version': version,
  'created_at': _now,
  'updated_at': _now,
  'lock': ?lock,
  'properties': properties,
  'tags': tags,
};

Map<String, Object?> _lockJson({
  String holder = 'cedric',
  String expiresAt = '2025-01-01T00:01:00.000Z',
}) => <String, Object?>{'holder': holder, 'expires_at': expiresAt};

DatabaseDefinition _projectsDb() => DatabaseDefinition(
  id: '01D',
  title: 'Projects DB',
  version: 1,
  source: const DatabaseSource.folder('Projects'),
  properties: const {
    'status': PropertyDefinition(
      type: PropertyType.select,
      options: ['Idea', 'Active', 'Done'],
    ),
  },
  views: const [],
  createdAt: DateTime.parse(_now),
  updatedAt: DateTime.parse(_now),
);

void main() {
  group('NoteController properties', () {
    test('open() loads properties and covering definitions', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/notes/01H') {
          return http.Response(
            jsonEncode(_noteJson(properties: {'status': 'Idea'})),
            200,
          );
        }
        return http.Response('unexpected ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        allDatabaseDefinitions: () async => [_projectsDb()],
      );
      addTearDown(ctrl.dispose);

      await ctrl.open();
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.properties, {'status': 'Idea'});
      expect(ctrl.value.coveringDefinitions.single.id, '01D');
    });

    test(
      'a note outside every database source has no covering definitions',
      () async {
        final mock = MockClient((request) async {
          if (request.url.path == '/notes/01H') {
            return http.Response(jsonEncode(_noteJson(path: 'Elsewhere')), 200);
          }
          return http.Response('unexpected', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final ctrl = NoteController(
          api: api,
          noteId: '01H',
          actor: 'cedric',
          allDatabaseDefinitions: () async => [_projectsDb()],
        );
        addTearDown(ctrl.dispose);

        await ctrl.open();
        await Future<void>.delayed(Duration.zero);

        expect(ctrl.value.coveringDefinitions, isEmpty);
      },
    );

    test(
      'patchProperty sends the patch and adopts the returned version',
      () async {
        final puts = <String>[];
        final mock = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path == '/notes/01H') {
            return http.Response(jsonEncode(_noteJson()), 200);
          }
          if (request.method == 'POST' && path == '/notes/01H/lock') {
            return http.Response(jsonEncode(_lockJson()), 200);
          }
          if (request.method == 'PATCH' && path == '/notes/01H/properties') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['set'], {'status': 'Active'});
            return http.Response(
              jsonEncode(
                _noteJson(version: 4, properties: {'status': 'Active'}),
              ),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/notes/01H') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            puts.add(request.headers['If-Match']!);
            return http.Response(
              jsonEncode(
                _noteJson(
                  version: (body['title'] == 'hello') ? 4 : 5,
                  properties: {'status': 'Active'},
                ),
              ),
              200,
            );
          }
          return http.Response('unexpected $path', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final ctrl = NoteController(
          api: api,
          noteId: '01H',
          actor: 'cedric',
          scheduler: (_) => Completer<void>().future,
        );
        addTearDown(ctrl.dispose);

        await ctrl.open();
        await ctrl.enterEditMode();
        expect(ctrl.value.note?.version, 1);

        await ctrl.patchProperty(set: {'status': 'Active'});

        expect(ctrl.value.properties, {'status': 'Active'});
        expect(ctrl.value.note?.version, 4);
        // The buffers must be untouched by the patch.
        expect(ctrl.value.editTitle, 'hello');
        expect(ctrl.value.editContent, 'world');

        await ctrl.save();
        expect(puts.single, '4');
      },
    );

    test('patch during an armed autosave causes no conflict: autosave is '
        're-armed at the version the patch returned', () async {
      final puts = <String>[];
      Completer<void>? gate;
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'PATCH' && path == '/notes/01H/properties') {
          return http.Response(
            jsonEncode(_noteJson(version: 4, properties: {'status': 'Active'})),
            200,
          );
        }
        if (request.method == 'PUT' && path == '/notes/01H') {
          puts.add(request.headers['If-Match']!);
          return http.Response(jsonEncode(_noteJson(version: 5)), 200);
        }
        return http.Response('unexpected $path', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future,
        autosaveScheduler: (_) async {
          gate = Completer<void>();
          await gate!.future;
        },
      );
      addTearDown(ctrl.dispose);

      await ctrl.open();
      await ctrl.enterEditMode();
      ctrl.setEditContent('typed');
      // Autosave timer armed at version 3 (per scenario) — here loaded
      // version 1; what matters is that it's cancelled and re-armed.
      final firstGate = gate;

      await ctrl.patchProperty(set: {'status': 'Active'});

      // A fresh autosave was armed (a new gate, distinct from the one
      // cancelled by the patch).
      expect(gate, isNot(same(firstGate)));
      expect(ctrl.value.note?.version, 4);

      gate!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(puts.single, '4');
    });

    test('patchProperty waits for an in-flight save before sending', () async {
      final order = <String>[];
      final saveGate = Completer<void>();
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'PUT' && path == '/notes/01H') {
          order.add('save-start');
          await saveGate.future;
          order.add('save-end');
          return http.Response(jsonEncode(_noteJson(version: 2)), 200);
        }
        if (request.method == 'PATCH' && path == '/notes/01H/properties') {
          order.add('patch-sent');
          return http.Response(
            jsonEncode(_noteJson(version: 3, properties: {'status': 'Active'})),
            200,
          );
        }
        return http.Response('unexpected $path', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future,
      );
      addTearDown(ctrl.dispose);

      await ctrl.open();
      await ctrl.enterEditMode();
      ctrl.setEditContent('typed');
      final saveFuture = ctrl.save();
      // Let the PUT request actually start before racing the patch.
      await Future<void>.delayed(Duration.zero);
      expect(order, ['save-start']);

      final patchFuture = ctrl.patchProperty(set: {'status': 'Active'});
      await Future<void>.delayed(Duration.zero);
      // The patch must not have been sent yet — the save is in flight.
      expect(order, ['save-start']);

      saveGate.complete();
      await saveFuture;
      await patchFuture;

      expect(order, ['save-start', 'save-end', 'patch-sent']);
    });

    test('a changed event while editing refreshes properties only, never '
        'the buffers or the version baseline', () async {
      var gets = 0;
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/notes/01H') {
          gets += 1;
          return http.Response(
            jsonEncode(
              gets <= 2
                  // open()'s fetch, then enterEditMode's post-lock
                  // re-fetch: both still show the pre-event state.
                  ? _noteJson(properties: {'status': 'Idea'})
                  : _noteJson(
                      version: 9, // an agent's edit bumped this server-side
                      content: 'server rewrote this',
                      properties: {'status': 'Active'},
                    ),
            ),
            200,
          );
        }
        if (request.method == 'POST' && path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        return http.Response('unexpected $path', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final events = StreamController<RealtimeEvent>();
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future,
        events: events.stream,
      );
      addTearDown(ctrl.dispose);
      addTearDown(events.close);

      await ctrl.open();
      await ctrl.enterEditMode();
      ctrl.setEditContent('my unsaved edit');
      expect(ctrl.value.note?.version, 1);

      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01H',
            version: 9,
            by: 'agent',
            action: ChangeAction.updated,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.properties, {'status': 'Active'});
      // Buffers and the If-Match baseline are untouched.
      expect(ctrl.value.editContent, 'my unsaved edit');
      expect(ctrl.value.note?.version, 1);
      expect(ctrl.value.note?.content, 'world');
    });

    test('a changed event while viewing (not editing) still does the '
        'existing full refresh', () async {
      var gets = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/notes/01H') {
          gets += 1;
          return http.Response(
            jsonEncode(
              gets == 1
                  ? _noteJson()
                  : _noteJson(version: 2, content: 'refreshed'),
            ),
            200,
          );
        }
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final events = StreamController<RealtimeEvent>();
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        events: events.stream,
      );
      addTearDown(ctrl.dispose);
      addTearDown(events.close);

      await ctrl.open();
      events.add(
        const RealtimeMessage(
          ChangedEvent(
            noteId: '01H',
            version: 2,
            by: 'agent',
            action: ChangeAction.updated,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.note?.version, 2);
      expect(ctrl.value.note?.content, 'refreshed');
    });
  });
}
