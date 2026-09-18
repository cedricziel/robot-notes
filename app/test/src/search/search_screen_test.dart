import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/notes_list_screen.dart' show formatNoteTimestamp;
import 'package:app/src/search/search_controller.dart';
import 'package:app/src/search/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

NoteMeta _recentNote({required String id, required String title}) => NoteMeta(
  id: id,
  title: title,
  version: 1,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

http.Response _hits(List<String> ids) => http.Response(
  jsonEncode(<String, Object?>{
    'items': <Object?>[
      for (final id in ids)
        <String, Object?>{
          'id': id,
          'title': 'doc $id',
          'snippet': 'hi',
          'rank': -1.0,
          'updated_at': '2026-01-01T00:00:00.000Z',
        },
    ],
    'limit': 50,
  }),
  200,
);

http.Response _badRequest(String message) => http.Response(
  jsonEncode(<String, Object?>{'error': 'bad_request', 'message': message}),
  400,
);

http.Response _unauthorized(String message) => http.Response(
  jsonEncode(<String, Object?>{'error': 'unauthorized', 'message': message}),
  401,
);

void main() {
  testWidgets('typing produces results and tapping invokes onResultTap', (
    tester,
  ) async {
    String? capturedPath;
    String? capturedQ;
    final mock = MockClient((request) async {
      capturedPath = request.url.path;
      capturedQ = request.url.queryParameters['q'];
      return http.Response(
        jsonEncode(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'id': '01H',
              'title': 'doc',
              'snippet': 'pre <mark>hello</mark> post',
              'rank': -1.0,
              'updated_at': '2026-01-01T00:00:00.000Z',
            },
          ],
          'limit': 50,
        }),
        200,
      );
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(
      api: api,
      // Synchronous scheduler so the widget test doesn't need timers.
      scheduler: (_) async {},
    );
    addTearDown(ctrl.dispose);

    String? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: SearchScreen(controller: ctrl, onResultTap: (id) => tapped = id),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'hello');
    // Drain microtasks (scheduler + http roundtrip) and pump a frame so
    // the new value of the controller renders. We avoid pumpAndSettle
    // because the loading-state CircularProgressIndicator animates
    // forever.
    await tester.pump();
    await tester.pump();

    expect(capturedPath, '/search');
    expect(capturedQ, 'hello');
    expect(find.byKey(const Key('search.hit.01H')), findsOneWidget);
    expect(find.byKey(const Key('search.snippet')), findsAtLeastNWidgets(1));

    await tester.tap(find.byKey(const Key('search.hit.01H')));
    await tester.pump();
    expect(tapped, '01H');
  });

  testWidgets('emptying the field returns the prompt and issues no request', (
    tester,
  ) async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return http.Response(
        jsonEncode(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'id': '01H',
              'title': 'doc',
              'snippet': 'hi',
              'rank': -1.0,
              'updated_at': '2026-01-01T00:00:00.000Z',
            },
          ],
          'limit': 50,
        }),
        200,
      );
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'hello');
    await tester.pump();
    await tester.pump();
    expect(calls, 1);

    await tester.enterText(find.byKey(const Key('search.input')), '');
    await tester.pump();

    expect(calls, 1);
    expect(find.text('Type to search.'), findsOneWidget);
  });

  group('recent notes', () {
    testWidgets('shows a Recent section before the user types anything', (
      tester,
    ) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SearchScreen(
            controller: ctrl,
            recentNotes: [
              _recentNote(id: '01H', title: 'Weekend Trip'),
              _recentNote(id: '02H', title: 'Grocery List'),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Weekend Trip'), findsOneWidget);
      expect(find.text('Grocery List'), findsOneWidget);
    });

    testWidgets('tapping a recent note invokes onResultTap', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
      addTearDown(ctrl.dispose);
      String? tapped;

      await tester.pumpWidget(
        MaterialApp(
          home: SearchScreen(
            controller: ctrl,
            recentNotes: [_recentNote(id: '01H', title: 'Weekend Trip')],
            onResultTap: (id) => tapped = id,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Weekend Trip'));
      await tester.pump();

      expect(tapped, '01H');
    });

    testWidgets('falls back to the empty-state hint when there are no '
        'recent notes', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: SearchScreen(controller: ctrl)),
      );
      await tester.pump();

      expect(find.text('Recent'), findsNothing);
      expect(find.text('Type to search.'), findsOneWidget);
    });

    testWidgets('the Recent section is replaced once the user types', (
      tester,
    ) async {
      final mock = MockClient((request) async => _hits(['03H']));
      final api = RobotNotesClient(config: _config, httpClient: mock);
      final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SearchScreen(
            controller: ctrl,
            recentNotes: [_recentNote(id: '01H', title: 'Weekend Trip')],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Recent'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('search.input')), 'trip');
      await tester.pump();
      await tester.pump();

      expect(find.text('Recent'), findsNothing);
    });
  });

  testWidgets('an API error with no results shows the message centred', (
    tester,
  ) async {
    final mock = MockClient((request) async => _badRequest('unbalanced "'));
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs "');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('search.error')), findsOneWidget);
    expect(find.text('unbalanced "'), findsOneWidget);
    expect(find.text('No matches.'), findsNothing);
  });

  testWidgets('an API error over stale results shows a strip above them', (
    tester,
  ) async {
    final mock = MockClient((request) async {
      final q = request.url.queryParameters['q'];
      return q == 'zfs' ? _hits(<String>['01H']) : _badRequest('bad query');
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('search.hit.01H')), findsOneWidget);
    expect(find.byKey(const Key('search.error')), findsNothing);

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs "');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('search.error')), findsOneWidget);
    expect(find.text('bad query'), findsOneWidget);
    expect(find.byKey(const Key('search.hit.01H')), findsOneWidget);
  });

  testWidgets('a new query over old results shows a progress bar', (
    tester,
  ) async {
    final second = Completer<http.Response>();
    var calls = 0;
    final mock = MockClient((request) async {
      calls += 1;
      return calls == 1 ? _hits(<String>['01H']) : second.future;
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs');
    await tester.pump();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs pool');
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('search.hit.01H')), findsOneWidget);

    second.complete(_hits(<String>['02H']));
    await tester.pump();
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byKey(const Key('search.hit.02H')), findsOneWidget);
  });

  testWidgets('parseSnippet emits bold spans for <mark>…</mark>', (
    tester,
  ) async {
    late List<InlineSpan> spans;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            spans = parseSnippet('one <mark>two</mark> three', context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(spans, hasLength(3));
    expect((spans[0] as TextSpan).text, 'one ');
    expect((spans[1] as TextSpan).text, 'two');
    expect((spans[1] as TextSpan).style?.fontWeight, FontWeight.bold);
    expect((spans[2] as TextSpan).text, ' three');
  });

  testWidgets('clear button appears once typed, clears the field, and '
      'refocuses it', (tester) async {
    final mock = MockClient((request) async => _hits(<String>['01H']));
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    expect(find.byKey(const Key('search.clear')), findsNothing);

    await tester.enterText(find.byKey(const Key('search.input')), 'hello');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('search.clear')), findsOneWidget);

    await tester.tap(find.byKey(const Key('search.clear')));
    await tester.pump();

    expect(find.byKey(const Key('search.clear')), findsNothing);
    final field = tester.widget<TextField>(
      find.byKey(const Key('search.input')),
    );
    expect(field.controller!.text, isEmpty);
    expect(ctrl.value.query, isEmpty);
    expect(
      FocusScope.of(tester.element(find.byType(SearchScreen))).hasFocus,
      isTrue,
    );
  });

  testWidgets('result count line shows the match count, singular and plural', (
    tester,
  ) async {
    var responseIds = <String>['01H'];
    final mock = MockClient((request) async => _hits(responseIds));
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('search.count')), findsOneWidget);
    expect(find.text('1 match'), findsOneWidget);

    responseIds = <String>['01H', '02H', '03H'];
    await tester.enterText(find.byKey(const Key('search.input')), 'zfs2');
    await tester.pump();
    await tester.pump();

    expect(find.text('3 matches'), findsOneWidget);
  });

  testWidgets('empty results show a query-specific message', (tester) async {
    final mock = MockClient((request) async => _hits(<String>[]));
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'zzzqux');
    await tester.pump();
    await tester.pump();

    expect(find.text('No matches for “zzzqux”.'), findsOneWidget);
  });

  testWidgets('a 400 error shows a syntax hint; other errors do not', (
    tester,
  ) async {
    final mock = MockClient((request) async => _badRequest('bad query'));
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs "');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('search.hint')), findsOneWidget);
    expect(find.text('Check quotes and special characters.'), findsOneWidget);
  });

  testWidgets('a non-400 error does not show the syntax hint', (tester) async {
    final mock = MockClient((request) async => _unauthorized('bad key'));
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('search.error')), findsOneWidget);
    expect(find.byKey(const Key('search.hint')), findsNothing);
  });

  group('overlay chrome', () {
    testWidgets('renders no Scaffold or AppBar of its own', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Dialog(
            child: SearchScreen(controller: ctrl, onClose: () {}),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(Scaffold), findsNothing);
      expect(find.byKey(const Key('search.input')), findsOneWidget);
    });

    testWidgets('the close button is absent without onClose', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(home: SearchScreen(controller: ctrl)),
      );
      await tester.pump();

      expect(find.byKey(const Key('search.close')), findsNothing);
    });

    testWidgets('the close button is present with onClose and invokes it', (
      tester,
    ) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
      addTearDown(ctrl.dispose);
      var closed = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SearchScreen(controller: ctrl, onClose: () => closed += 1),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('search.close')), findsOneWidget);
      await tester.tap(find.byKey(const Key('search.close')));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('fills a constrained parent without overflowing', (
      tester,
    ) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 320,
              height: 400,
              child: SearchScreen(
                controller: ctrl,
                onClose: () {},
                recentNotes: [_recentNote(id: '01H', title: 'Weekend Trip')],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SearchScreen)), const Size(320, 400));
      expect(find.text('Weekend Trip'), findsOneWidget);
    });
  });

  testWidgets('a hit tile shows the note\'s formatted updated time', (
    tester,
  ) async {
    final mock = MockClient((request) async {
      return http.Response(
        jsonEncode(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'id': '01H',
              'title': 'doc',
              'snippet': 'hi',
              'rank': -1.0,
              'updated_at': '2026-01-02T03:04:00.000Z',
            },
          ],
          'limit': 50,
        }),
        200,
      );
    });
    final api = RobotNotesClient(config: _config, httpClient: mock);
    final ctrl = NotesSearchController(api: api, scheduler: (_) async {});
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(home: SearchScreen(controller: ctrl)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('search.input')), 'zfs');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('search.hit.01H.updated')), findsOneWidget);
    expect(
      find.text(
        formatNoteTimestamp(DateTime.parse('2026-01-02T03:04:00.000Z')),
      ),
      findsOneWidget,
    );
  });
}
