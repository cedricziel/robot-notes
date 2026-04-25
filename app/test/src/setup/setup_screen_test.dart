import 'dart:convert';

import 'package:app/src/config/app_config.dart';
import 'package:app/src/config/config_store.dart';
import 'package:app/src/setup/setup_controller.dart';
import 'package:app/src/setup/setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('renders three inputs (URL, key, actor) and a submit button',
      (tester) async {
    final controller = SetupController(
      store: InMemoryConfigStore(),
      clientFactory: () => MockClient((_) async => http.Response('', 200)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(controller: controller, onConfigured: (_) {}),
      ),
    );

    expect(find.byKey(const Key('setup.baseUrl')), findsOneWidget);
    expect(find.byKey(const Key('setup.apiKey')), findsOneWidget);
    expect(find.byKey(const Key('setup.actor')), findsOneWidget);
    expect(find.byKey(const Key('setup.submit')), findsOneWidget);
  });

  testWidgets('successful submit calls onConfigured with normalized config',
      (tester) async {
    final store = InMemoryConfigStore();
    final mock = MockClient((request) async {
      if (request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200);
      }
      return http.Response(
        jsonEncode(<String, Object?>{'items': <Object?>[], 'next': null}),
        200,
      );
    });
    final controller = SetupController(
      store: store,
      clientFactory: () => mock,
    );

    AppConfig? configured;
    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(
          controller: controller,
          onConfigured: (AppConfig c) => configured = c,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('setup.baseUrl')),
      'https://notes.example/',
    );
    await tester.enterText(
      find.byKey(const Key('setup.apiKey')),
      'good-key',
    );
    await tester.enterText(
      find.byKey(const Key('setup.actor')),
      'cedric',
    );

    await tester.tap(find.byKey(const Key('setup.submit')));
    await tester.pumpAndSettle();

    expect(configured, isNotNull);
    expect(configured!.baseUrl, 'https://notes.example');
    expect(configured!.actor, 'cedric');
  });

  testWidgets('401 surfaces an inline error and does not call onConfigured',
      (tester) async {
    final mock = MockClient((request) async {
      if (request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200);
      }
      return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
    });
    final controller = SetupController(
      store: InMemoryConfigStore(),
      clientFactory: () => mock,
    );

    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(
          controller: controller,
          onConfigured: (_) => calls += 1,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('setup.baseUrl')),
      'https://notes.example',
    );
    await tester.enterText(
      find.byKey(const Key('setup.apiKey')),
      'wrong',
    );
    await tester.enterText(
      find.byKey(const Key('setup.actor')),
      'cedric',
    );
    await tester.tap(find.byKey(const Key('setup.submit')));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('API key was rejected by the server.'), findsOneWidget);
  });
}
