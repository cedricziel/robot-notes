import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/api/api_exceptions.dart';
import 'package:app/src/config/app_config.dart';
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
  String title = 'hi',
  String content = 'body',
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

void main() {
  group('RobotNotesClient', () {
    test('every request carries Authorization and X-Actor headers', () async {
      final seen = <Map<String, String>>[];
      final mock = MockClient((request) async {
        seen.add(<String, String>{
          for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
        });
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.listNotes();
      // Hit a second endpoint to prove headers attach to every call, not just one.
      await client.search(q: 'hello');

      expect(seen, hasLength(2));
      for (final h in seen) {
        expect(h['authorization'], 'Bearer test-key');
        expect(h['x-actor'], 'cedric');
      }
    });

    test('401 surfaces a typed Unauthorized exception', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'unauthorized'}),
          401,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);

      await expectLater(
        client.listNotes(),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('409 surfaces VersionConflict with the current note state', () async {
      final mock = MockClient((request) async {
        if (request.method != 'PUT') {
          return http.Response('{}', 500);
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'version_conflict',
            'current': _noteJson(id: '01H', version: 7, content: 'newer'),
          }),
          409,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);

      try {
        await client.updateNote(
          id: '01H',
          title: 'hi',
          content: 'mine',
          ifMatch: 3,
        );
        fail('expected VersionConflictException');
      } on VersionConflictException catch (e) {
        expect(e.current.id, '01H');
        expect(e.current.version, 7);
        expect(e.current.content, 'newer');
      }
    });

    test('423 surfaces Locked with holder and expires_at', () async {
      final expiresAt = DateTime.utc(
        2025,
        1,
        1,
        0,
        5,
      ).toUtc().toIso8601String();
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'locked',
            'lock': <String, Object?>{
              'holder': 'alice',
              'expires_at': expiresAt,
            },
          }),
          423,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);

      try {
        await client.updateNote(
          id: '01H',
          title: 'hi',
          content: 'mine',
          ifMatch: 1,
        );
        fail('expected LockedException');
      } on LockedException catch (e) {
        expect(e.lock.holder, 'alice');
        expect(e.lock.expiresAt.toUtc().toIso8601String(), expiresAt);
      }
    });

    test('list/read/create/update/delete/lock/search end-to-end', () async {
      final calls = <String>[];
      final mock = MockClient((request) async {
        final tag =
            '${request.method} ${request.url.path}'
            '${request.url.query.isEmpty ? '' : '?${request.url.query}'}';
        calls.add(tag);

        // GET /notes (list)
        if (request.method == 'GET' && request.url.path == '/notes') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'id': '01H',
                  'title': 'hi',
                  'version': 1,
                  'created_at': _now,
                  'updated_at': _now,
                },
              ],
              'limit': 50,
              'next_cursor': null,
            }),
            200,
          );
        }
        // GET /notes/01H (read)
        if (request.method == 'GET' && request.url.path == '/notes/01H') {
          return http.Response(jsonEncode(_noteJson()), 200);
        }
        // POST /notes (create)
        if (request.method == 'POST' && request.url.path == '/notes') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['title'], 'new');
          return http.Response(
            jsonEncode(_noteJson(id: '02H', title: 'new')),
            201,
          );
        }
        // PUT /notes/01H (update)
        if (request.method == 'PUT' && request.url.path == '/notes/01H') {
          expect(request.headers['if-match'], '1');
          return http.Response(
            jsonEncode(_noteJson(version: 2, content: 'edited')),
            200,
          );
        }
        // DELETE /notes/01H
        if (request.method == 'DELETE' && request.url.path == '/notes/01H') {
          return http.Response('', 204);
        }
        // POST /notes/01H/lock (acquire)
        if (request.method == 'POST' && request.url.path == '/notes/01H/lock') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'holder': 'cedric',
              'expires_at': _now,
            }),
            200,
          );
        }
        // PUT /notes/01H/lock (heartbeat)
        if (request.method == 'PUT' && request.url.path == '/notes/01H/lock') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'holder': 'cedric',
              'expires_at': _now,
            }),
            200,
          );
        }
        // DELETE /notes/01H/lock (release)
        if (request.method == 'DELETE' &&
            request.url.path == '/notes/01H/lock') {
          return http.Response('', 204);
        }
        // GET /search
        if (request.method == 'GET' && request.url.path == '/search') {
          expect(request.url.queryParameters['q'], 'hello');
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'id': '01H',
                  'title': 'hi',
                  'snippet': 'hello world',
                  'rank': -1.5,
                  'updated_at': _now,
                },
              ],
              'limit': 50,
            }),
            200,
          );
        }
        return http.Response('unhandled: $tag', 500);
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);

      final page = await client.listNotes();
      expect(page.items, hasLength(1));
      expect(page.items.first, isA<NoteMeta>());
      expect(page.nextCursor, isNull);

      final note = await client.getNote('01H');
      expect(note.id, '01H');
      expect(note.lock, isNull);

      final created = await client.createNote(title: 'new');
      expect(created.id, '02H');

      final updated = await client.updateNote(
        id: '01H',
        title: 'hi',
        content: 'edited',
        ifMatch: 1,
      );
      expect(updated.version, 2);
      expect(updated.content, 'edited');

      await client.deleteNote('01H');

      final lock = await client.acquireLock('01H');
      expect(lock.holder, 'cedric');

      final beat = await client.heartbeatLock('01H');
      expect(beat.holder, 'cedric');

      await client.releaseLock('01H');

      final hits = await client.search(q: 'hello');
      expect(hits, hasLength(1));
      expect(hits.first.title, 'hi');
      expect(hits.first.snippet, 'hello world');

      expect(calls, [
        'GET /notes',
        'GET /notes/01H',
        'POST /notes',
        'PUT /notes/01H',
        'DELETE /notes/01H',
        'POST /notes/01H/lock',
        'PUT /notes/01H/lock',
        'DELETE /notes/01H/lock',
        'GET /search?q=hello',
      ]);
    });

    test('pagination cursor and limit are forwarded as query params', () async {
      Uri? captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[],
            'limit': 25,
            'next_cursor': null,
          }),
          200,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.listNotes(after: '01G', limit: 25);

      expect(captured, isNotNull);
      expect(captured!.queryParameters['after'], '01G');
      expect(captured!.queryParameters['limit'], '25');
    });

    test('sort is forwarded as a query param when given', () async {
      Uri? captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.listNotes(sort: 'updated_desc');

      expect(captured, isNotNull);
      expect(captured!.queryParameters['sort'], 'updated_desc');
    });

    test('sort is omitted when not given', () async {
      Uri? captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.listNotes();

      expect(captured, isNotNull);
      expect(captured!.queryParameters.containsKey('sort'), isFalse);
    });

    test('path and tag are forwarded as query params when given', () async {
      Uri? captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.listNotes(path: 'Projects/Alpha', tag: 'urgent');

      expect(captured, isNotNull);
      expect(captured!.queryParameters['path'], 'Projects/Alpha');
      expect(captured!.queryParameters['tag'], 'urgent');
    });

    test('path and tag are omitted when not given', () async {
      Uri? captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[],
            'limit': 50,
            'next_cursor': null,
          }),
          200,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.listNotes();

      expect(captured!.queryParameters.containsKey('path'), isFalse);
      expect(captured!.queryParameters.containsKey('tag'), isFalse);
    });

    test('getTree parses folders with note counts', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/notes/tree');
        return http.Response(
          jsonEncode(<String, Object?>{
            'folders': <Object?>[
              <String, Object?>{'path': '', 'note_count': 2},
              <String, Object?>{'path': 'Projects/Alpha', 'note_count': 3},
            ],
          }),
          200,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      final tree = await client.getTree();

      expect(tree.folders, hasLength(2));
      expect(tree.folders[0].path, '');
      expect(tree.folders[0].noteCount, 2);
      expect(tree.folders[1].path, 'Projects/Alpha');
      expect(tree.folders[1].noteCount, 3);
    });

    test('createNote sends path when creating inside a folder', () async {
      Map<String, dynamic>? body;
      final mock = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(_noteJson()), 201);
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.createNote(title: 'new', path: 'Projects/Alpha');

      expect(body?['path'], 'Projects/Alpha');
    });

    test('createFolder posts the path to /notes/tree', () async {
      Map<String, dynamic>? body;
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/notes/tree');
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, Object?>{'path': 'Ideas', 'note_count': 0}),
          201,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.createFolder('Ideas');

      expect(body?['path'], 'Ideas');
    });

    test('createFolder surfaces a 400 as BadRequestException', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'bad_request',
            'message': 'path is required',
          }),
          400,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);

      await expectLater(
        client.createFolder(''),
        throwsA(isA<BadRequestException>()),
      );
    });

    test('uploadFile posts a multipart request to /notes/files', () async {
      String? capturedPath;
      String? capturedMethod;
      Map<String, String>? capturedFields;
      String? capturedFilename;
      List<int>? capturedBytes;
      final mock = MockClient.streaming((request, bodyStream) async {
        capturedMethod = request.method;
        capturedPath = request.url.path;
        final multipart = request as http.MultipartRequest;
        capturedFields = multipart.fields;
        capturedFilename = multipart.files.single.filename;
        capturedBytes = await multipart.files.single.finalize().toBytes();
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'path': 'Ideas',
                'filename': 'diagram.png',
                'size': 3,
                'content_type': 'image/png',
              }),
            ),
          ),
          201,
          request: request,
        );
      });
      final client = RobotNotesClient(config: _config, httpClient: mock);

      final result = await client.uploadFile(
        path: 'Ideas',
        filename: 'diagram.png',
        bytes: [1, 2, 3],
        contentType: 'image/png',
      );

      expect(capturedMethod, 'POST');
      expect(capturedPath, '/notes/files');
      expect(capturedFields?['path'], 'Ideas');
      expect(capturedFilename, 'diagram.png');
      expect(capturedBytes, [1, 2, 3]);
      expect(result.path, 'Ideas');
      expect(result.filename, 'diagram.png');
      expect(result.size, 3);
      expect(result.contentType, 'image/png');
    });

    test('uploadFile surfaces a 409 as PathConflictException', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'path_conflict'}),
          409,
        );
      });
      final client = RobotNotesClient(config: _config, httpClient: mock);

      await expectLater(
        client.uploadFile(path: 'Ideas', filename: 'a.png', bytes: [1]),
        throwsA(isA<PathConflictException>()),
      );
    });

    test('uploadFile surfaces a 413 as PayloadTooLargeException', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'payload_too_large'}),
          413,
        );
      });
      final client = RobotNotesClient(config: _config, httpClient: mock);

      await expectLater(
        client.uploadFile(path: '', filename: 'big.bin', bytes: [1]),
        throwsA(isA<PayloadTooLargeException>()),
      );
    });

    test('updateNote sends path when moving a note', () async {
      Map<String, dynamic>? body;
      final mock = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(_noteJson(version: 2)), 200);
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      await client.updateNote(
        id: '01H',
        title: 'hi',
        content: 'body',
        ifMatch: 1,
        path: 'Projects/Alpha',
      );

      expect(body?['path'], 'Projects/Alpha');
    });

    test('409 path_conflict surfaces a typed PathConflictException', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'path_conflict'}),
          409,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);

      await expectLater(
        client.updateNote(
          id: '01H',
          title: 'hi',
          content: 'body',
          ifMatch: 1,
          path: 'Projects/Alpha',
        ),
        throwsA(isA<PathConflictException>()),
      );
    });

    test('getBacklinks parses referencing notes with snippets', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/notes/01H/backlinks');
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'id': '02H',
                'title': 'Referencing note',
                'snippet': 'links to [[Hello]] here',
              },
            ],
          }),
          200,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);
      final backlinks = await client.getBacklinks('01H');

      expect(backlinks, hasLength(1));
      expect(backlinks.single.id, '02H');
      expect(backlinks.single.title, 'Referencing note');
      expect(backlinks.single.snippet, 'links to [[Hello]] here');
    });

    test('400 surfaces BadRequest with server-supplied message', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'bad_request',
            'message': 'title is required',
          }),
          400,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);

      try {
        await client.createNote(title: '');
        fail('expected BadRequestException');
      } on BadRequestException catch (e) {
        expect(e.message, 'title is required');
      }
    });

    test('404 surfaces NotFound', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'not_found'}),
          404,
        );
      });

      final client = RobotNotesClient(config: _config, httpClient: mock);

      await expectLater(
        client.getNote('missing'),
        throwsA(isA<NotFoundException>()),
      );
    });
  });
}
