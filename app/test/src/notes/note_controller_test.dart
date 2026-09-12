import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/api/api_exceptions.dart';
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
  int version = 1,
  Map<String, Object?>? lock,
}) => <String, Object?>{
  'id': id,
  'title': title,
  'content': content,
  'version': version,
  'created_at': _now,
  'updated_at': _now,
  'lock': ?lock,
};

Map<String, Object?> _lockJson({
  String holder = 'cedric',
  String expiresAt = '2025-01-01T00:01:00.000Z',
}) => <String, Object?>{'holder': holder, 'expires_at': expiresAt};

void main() {
  group('NoteController', () {
    test(
      'open() fetches the note and asks the WS layer to subscribe',
      () async {
        var listGets = 0;
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes/01H') {
            listGets += 1;
            return http.Response(jsonEncode(_noteJson()), 200);
          }
          return http.Response('unexpected', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final subscribed = <String>[];
        final ctrl = NoteController(
          api: api,
          noteId: '01H',
          actor: 'cedric',
          onSubscribe: subscribed.add,
        );
        addTearDown(ctrl.dispose);

        await ctrl.open();

        expect(listGets, 1);
        expect(subscribed, <String>['01H']);
        expect(ctrl.value.mode, NoteMode.viewing);
        expect(ctrl.value.note?.id, '01H');
      },
    );

    test('enterEditMode acquires the lock and switches to editing', () async {
      final mock = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        return http.Response('unexpected ${request.url.path}', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        scheduler: (_) => Completer<void>().future, // never fire heartbeat
      );
      addTearDown(ctrl.dispose);

      await ctrl.open();
      await ctrl.enterEditMode();

      expect(ctrl.value.mode, NoteMode.editing);
      expect(ctrl.value.lock?.holder, 'cedric');
      expect(ctrl.value.editTitle, 'hello');
      expect(ctrl.value.editContent, 'world');
    });

    test(
      'enterEditMode re-fetches the note after the lock is acquired',
      () async {
        final calls = <String>[];
        var gets = 0;
        final mock = MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.method == 'GET' && request.url.path == '/notes/01H') {
            gets += 1;
            return http.Response(
              jsonEncode(
                gets == 1
                    ? _noteJson(version: 1)
                    : _noteJson(
                        version: 2,
                        title: 'fresh',
                        content: 'server moved on',
                        lock: _lockJson(),
                      ),
              ),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/notes/01H/lock') {
            return http.Response(jsonEncode(_lockJson()), 200);
          }
          return http.Response('unexpected ${request.url.path}', 500);
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
        expect(ctrl.value.note?.version, 1);

        await ctrl.enterEditMode();

        expect(calls, <String>[
          'GET /notes/01H',
          'POST /notes/01H/lock',
          'GET /notes/01H',
        ]);
        expect(ctrl.value.mode, NoteMode.editing);
        expect(ctrl.value.note?.version, 2);
        expect(ctrl.value.lock?.holder, 'cedric');
        expect(ctrl.value.editTitle, 'fresh');
        expect(ctrl.value.editContent, 'server moved on');
      },
    );

    test('enterEditMode releases the lock when the re-fetch fails', () async {
      final calls = <String>[];
      var gets = 0;
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          gets += 1;
          if (gets == 1) {
            return http.Response(jsonEncode(_noteJson()), 200);
          }
          return http.Response('boom', 500);
        }
        if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'DELETE' &&
            request.url.path == '/notes/01H/lock') {
          return http.Response('', 204);
        }
        return http.Response('unexpected ${request.url.path}', 500);
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

      expect(calls, contains('DELETE /notes/01H/lock'));
      expect(ctrl.value.mode, NoteMode.viewing);
      expect(ctrl.value.lock, isNull);
      expect(ctrl.value.editTitle, isNull);
      expect(ctrl.value.editContent, isNull);
      expect(ctrl.value.error, isA<ApiException>());
      expect(ctrl.value.note?.version, 1);
    });

    test(
      'enterEditMode on 423 stays in viewing mode with holder banner',
      () async {
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes/01H') {
            return http.Response(jsonEncode(_noteJson()), 200);
          }
          if (request.method == 'POST' &&
              request.url.path == '/notes/01H/lock') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'error': 'locked',
                'lock': _lockJson(holder: 'alice'),
              }),
              423,
            );
          }
          return http.Response('unexpected', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final ctrl = NoteController(api: api, noteId: '01H', actor: 'cedric');
        addTearDown(ctrl.dispose);

        await ctrl.open();
        await ctrl.enterEditMode();

        expect(ctrl.value.mode, NoteMode.viewing);
        expect(ctrl.value.lock?.holder, 'alice');
        expect(ctrl.value.error, isA<LockedException>());
      },
    );

    test('heartbeat fires at half the lock TTL while editing', () async {
      final scheduledDelays = <Duration>[];
      Completer<void>? gate;
      Completer<void> nextGate() {
        gate = Completer<void>();
        return gate!;
      }

      var heartbeats = 0;
      final mock = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'PUT' && request.url.path == '/notes/01H/lock') {
          heartbeats += 1;
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        clock: () => DateTime.utc(2025, 1, 1, 0, 0, 0),
        scheduler: (d) async {
          scheduledDelays.add(d);
          await nextGate().future;
        },
      );
      addTearDown(ctrl.dispose);

      await ctrl.open();
      await ctrl.enterEditMode();
      // The first scheduled delay should be exactly half the TTL (60s lock,
      // expires at 00:01:00; clock is 00:00:00 → halfTtl = 30s).
      expect(scheduledDelays, isNotEmpty);
      expect(scheduledDelays.first, const Duration(seconds: 30));
      expect(heartbeats, 0);

      // Release the gate so the heartbeat fires.
      gate!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(heartbeats, 1);
      expect(scheduledDelays.length, greaterThanOrEqualTo(2));
    });

    test('save sends If-Match with the loaded version', () async {
      String? sentIfMatch;
      final mock = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson(version: 3)), 200);
        }
        if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'PUT' && request.url.path == '/notes/01H') {
          sentIfMatch = request.headers['if-match'];
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(
              _noteJson(
                version: 4,
                title: body['title'] as String,
                content: body['content'] as String,
              ),
            ),
            200,
          );
        }
        return http.Response('unexpected', 500);
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
      ctrl.setEditTitle('hi');
      ctrl.setEditContent('updated');
      await ctrl.save();

      expect(sentIfMatch, '3');
      expect(ctrl.value.mode, NoteMode.editing);
      expect(ctrl.value.note?.version, 4);
      expect(ctrl.value.note?.content, 'updated');
    });

    test(
      'save 409 puts the controller into conflict mode with server state',
      () async {
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes/01H') {
            return http.Response(jsonEncode(_noteJson(version: 1)), 200);
          }
          if (request.method == 'POST' &&
              request.url.path == '/notes/01H/lock') {
            return http.Response(jsonEncode(_lockJson()), 200);
          }
          if (request.method == 'PUT' && request.url.path == '/notes/01H') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'error': 'version_conflict',
                'current': _noteJson(version: 7, content: 'theirs'),
              }),
              409,
            );
          }
          return http.Response('unexpected', 500);
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
        ctrl.setEditContent('mine');
        await ctrl.save();

        expect(ctrl.value.mode, NoteMode.conflict);
        expect(ctrl.value.conflictCurrent?.version, 7);
        expect(ctrl.value.conflictCurrent?.content, 'theirs');
        expect(ctrl.value.editContent, 'mine');
      },
    );

    test('save 423 mid-edit forces read-only with holder banner', () async {
      final mock = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'PUT' && request.url.path == '/notes/01H') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'locked',
              'lock': _lockJson(holder: 'alice'),
            }),
            423,
          );
        }
        return http.Response('unexpected', 500);
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
      await ctrl.save();

      expect(ctrl.value.mode, NoteMode.viewing);
      expect(ctrl.value.lock?.holder, 'alice');
      expect(ctrl.value.lockedByOtherBanner, contains('alice'));
    });

    test('exitEditing releases the lock and returns to viewing', () async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
          return http.Response(jsonEncode(_lockJson()), 200);
        }
        if (request.method == 'DELETE' &&
            request.url.path == '/notes/01H/lock') {
          return http.Response('', 204);
        }
        return http.Response('unexpected', 500);
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
      await ctrl.exitEditing();

      expect(ctrl.value.mode, NoteMode.viewing);
      expect(ctrl.value.lock, isNull);
      expect(calls, contains('DELETE /notes/01H/lock'));
    });

    test('presence events update the viewers list', () async {
      final mock = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        return http.Response('unexpected', 500);
      });
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final events = StreamController<RealtimeEvent>.broadcast();
      addTearDown(events.close);
      final ctrl = NoteController(
        api: api,
        noteId: '01H',
        actor: 'cedric',
        events: events.stream,
      );
      addTearDown(ctrl.dispose);

      await ctrl.open();
      events.add(
        const RealtimeMessage(
          PresenceEvent(noteId: '01H', viewers: <String>['cedric', 'alice']),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.viewers, <String>['cedric', 'alice']);
    });

    test(
      'lock events update lock state without disturbing the editor',
      () async {
        final mock = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/notes/01H') {
            return http.Response(jsonEncode(_noteJson()), 200);
          }
          return http.Response('unexpected', 500);
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);
        final events = StreamController<RealtimeEvent>.broadcast();
        addTearDown(events.close);
        final ctrl = NoteController(
          api: api,
          noteId: '01H',
          actor: 'cedric',
          events: events.stream,
        );
        addTearDown(ctrl.dispose);

        await ctrl.open();
        events.add(
          RealtimeMessage(
            LockEvent(
              noteId: '01H',
              holder: 'alice',
              expiresAt: DateTime.utc(2025, 1, 1, 0, 1),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(ctrl.value.mode, NoteMode.viewing);
        expect(ctrl.value.lock?.holder, 'alice');

        // Now an unlock event clears it.
        events.add(const RealtimeMessage(LockEvent(noteId: '01H')));
        await Future<void>.delayed(Duration.zero);
        expect(ctrl.value.lock, isNull);
      },
    );

    group('delete', () {
      /// Answers the load, the lock choreography, and `DELETE /notes/01H`
      /// with [deleteStatus]; records every request in [calls].
      MockClient deleteMock(List<String> calls, {int deleteStatus = 204}) {
        return MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (request.method == 'GET' && path == '/notes/01H') {
            return http.Response(jsonEncode(_noteJson()), 200);
          }
          if (request.method == 'POST' && path == '/notes/01H/lock') {
            return http.Response(jsonEncode(_lockJson()), 200);
          }
          if (request.method == 'DELETE' && path == '/notes/01H/lock') {
            return http.Response('', 204);
          }
          if (request.method == 'DELETE' && path == '/notes/01H') {
            return http.Response('', deleteStatus);
          }
          return http.Response('unexpected $path', 500);
        });
      }

      NoteController controller(MockClient mock) {
        final ctrl = NoteController(
          api: RobotNotesClient(config: _config, httpClient: mock),
          noteId: '01H',
          actor: 'cedric',
          scheduler: (_) => Completer<void>().future,
        );
        addTearDown(ctrl.dispose);
        return ctrl;
      }

      test('issues DELETE /notes/{id} and ends in the deleted state', () async {
        final calls = <String>[];
        final ctrl = controller(deleteMock(calls));

        await ctrl.open();
        await ctrl.delete();

        expect(calls, <String>['GET /notes/01H', 'DELETE /notes/01H']);
        expect(ctrl.value.mode, NoteMode.deleted);
        expect(ctrl.value.error, isNull);
      });

      test('while editing releases the lock first', () async {
        final calls = <String>[];
        final ctrl = controller(deleteMock(calls));

        await ctrl.open();
        await ctrl.enterEditMode();
        await ctrl.delete();

        expect(calls.sublist(calls.length - 2), <String>[
          'DELETE /notes/01H/lock',
          'DELETE /notes/01H',
        ]);
        expect(ctrl.value.mode, NoteMode.deleted);
        expect(ctrl.value.lock, isNull);
        expect(ctrl.value.editTitle, isNull);
        expect(ctrl.value.editContent, isNull);
      });

      test('on 404 treats the note as already deleted', () async {
        final ctrl = controller(deleteMock(<String>[], deleteStatus: 404));

        await ctrl.open();
        await ctrl.delete();

        expect(ctrl.value.mode, NoteMode.deleted);
        expect(ctrl.value.error, isNull);
      });

      test('on 500 keeps viewing mode and sets the error', () async {
        final ctrl = controller(deleteMock(<String>[], deleteStatus: 500));

        await ctrl.open();
        await ctrl.delete();

        expect(ctrl.value.mode, NoteMode.viewing);
        expect(ctrl.value.note?.id, '01H');
        expect(ctrl.value.error, isA<ApiException>());
      });

      test('on 500 after releasing the lock falls back to viewing', () async {
        final ctrl = controller(deleteMock(<String>[], deleteStatus: 500));

        await ctrl.open();
        await ctrl.enterEditMode();
        await ctrl.delete();

        expect(ctrl.value.mode, NoteMode.viewing);
        expect(ctrl.value.lock, isNull);
        expect(ctrl.value.editTitle, isNull);
        expect(ctrl.value.error, isA<ApiException>());
      });

      test('is ignored while the DELETE is already in flight', () async {
        final calls = <String>[];
        final gate = Completer<void>();
        final mock = MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.method == 'GET') {
            return http.Response(jsonEncode(_noteJson()), 200);
          }
          await gate.future;
          return http.Response('', 204);
        });
        final ctrl = controller(mock);

        await ctrl.open();
        final first = ctrl.delete();
        expect(ctrl.value.mode, NoteMode.deleting);
        await ctrl.delete();
        gate.complete();
        await first;

        expect(calls.where((c) => c == 'DELETE /notes/01H').length, 1);
        expect(ctrl.value.mode, NoteMode.deleted);
      });
    });
  });
}
