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
  testWidgets('step 1 shows only the server URL field and a Continue button', (
    tester,
  ) async {
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
    expect(find.byKey(const Key('setup.continue')), findsOneWidget);
    expect(find.byKey(const Key('setup.apiKey')), findsNothing);
    expect(find.byKey(const Key('setup.actor')), findsNothing);
    expect(find.byKey(const Key('setup.submit')), findsNothing);
  });

  testWidgets('Continue advances to step 2 with the login options', (
    tester,
  ) async {
    final controller = SetupController(
      store: InMemoryConfigStore(),
      clientFactory: () => MockClient((_) async => http.Response('', 200)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(controller: controller, onConfigured: (_) {}),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('setup.baseUrl')),
      'https://notes.example',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('setup.continue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('setup.baseUrl')), findsNothing);
    expect(find.byKey(const Key('setup.changeServer')), findsOneWidget);
    expect(find.byKey(const Key('setup.apiKey')), findsOneWidget);
    expect(find.byKey(const Key('setup.actor')), findsOneWidget);
    expect(find.byKey(const Key('setup.submit')), findsOneWidget);
    expect(find.text('https://notes.example'), findsOneWidget);
  });

  testWidgets('Continue is disabled until a server URL is entered', (
    tester,
  ) async {
    final controller = SetupController(
      store: InMemoryConfigStore(),
      clientFactory: () => MockClient((_) async => http.Response('', 200)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(controller: controller, onConfigured: (_) {}),
      ),
    );

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('setup.continue')),
    );
    expect(button.onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('setup.baseUrl')),
      'https://notes.example',
    );
    await tester.pump();

    final enabledButton = tester.widget<FilledButton>(
      find.byKey(const Key('setup.continue')),
    );
    expect(enabledButton.onPressed, isNotNull);
  });

  testWidgets('Continue stays disabled for a non-https URL', (tester) async {
    final controller = SetupController(
      store: InMemoryConfigStore(),
      clientFactory: () => MockClient((_) async => http.Response('', 200)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(controller: controller, onConfigured: (_) {}),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('setup.baseUrl')),
      'http://notes.example',
    );
    await tester.pump();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('setup.continue')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Change server clears a stale error from the previous attempt', (
    tester,
  ) async {
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

    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(controller: controller, onConfigured: (_) {}),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('setup.baseUrl')),
      'https://notes.example',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('setup.continue')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('setup.apiKey')), 'wrong');
    await tester.enterText(find.byKey(const Key('setup.actor')), 'cedric');
    await tester.tap(find.byKey(const Key('setup.submit')));
    await tester.pumpAndSettle();

    expect(find.text('API key was rejected by the server.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('setup.changeServer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setup.continue')));
    await tester.pumpAndSettle();

    expect(find.text('API key was rejected by the server.'), findsNothing);
  });

  testWidgets('Change server returns to step 1 with the URL preserved', (
    tester,
  ) async {
    final controller = SetupController(
      store: InMemoryConfigStore(),
      clientFactory: () => MockClient((_) async => http.Response('', 200)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(controller: controller, onConfigured: (_) {}),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('setup.baseUrl')),
      'https://notes.example',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('setup.continue')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('setup.changeServer')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('setup.baseUrl')),
    );
    expect(field.controller!.text, 'https://notes.example');
  });

  testWidgets('successful submit calls onConfigured with normalized config', (
    tester,
  ) async {
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
    final controller = SetupController(store: store, clientFactory: () => mock);

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
    await tester.pump();
    await tester.tap(find.byKey(const Key('setup.continue')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('setup.apiKey')), 'good-key');
    await tester.enterText(find.byKey(const Key('setup.actor')), 'cedric');

    await tester.tap(find.byKey(const Key('setup.submit')));
    await tester.pumpAndSettle();

    expect(configured, isNotNull);
    expect(configured!.baseUrl, 'https://notes.example');
    expect(configured!.actor, 'cedric');
  });

  testWidgets('401 surfaces an inline error and does not call onConfigured', (
    tester,
  ) async {
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
    await tester.pump();
    await tester.tap(find.byKey(const Key('setup.continue')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('setup.apiKey')), 'wrong');
    await tester.enterText(find.byKey(const Key('setup.actor')), 'cedric');
    await tester.tap(find.byKey(const Key('setup.submit')));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('API key was rejected by the server.'), findsOneWidget);
  });
}
