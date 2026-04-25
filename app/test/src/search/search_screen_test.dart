import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/search/search_controller.dart';
import 'package:app/src/search/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

void main() {
  testWidgets('typing produces results and tapping invokes onResultTap',
      (tester) async {
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
        home: SearchScreen(
          controller: ctrl,
          onResultTap: (id) => tapped = id,
        ),
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

  testWidgets('emptying the field returns the prompt and issues no request',
      (tester) async {
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

    await tester.pumpWidget(
      MaterialApp(home: SearchScreen(controller: ctrl)),
    );
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

  testWidgets('parseSnippet emits bold spans for <mark>…</mark>',
      (tester) async {
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
}
