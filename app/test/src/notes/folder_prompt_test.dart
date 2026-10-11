import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/folder_prompt.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

/// Pumps a screen with a button that opens [showCreateFolderDialog], taps
/// it, and settles — leaving the dialog open. Returns a [Future] that
/// resolves to the dialog's eventual result once the caller interacts
/// with (and closes) it.
Future<Future<bool?>> _openDialog(
  WidgetTester tester, {
  required RobotNotesClient api,
  String? initialPath,
  bool reducedMotion = false,
}) async {
  final resultCompleter = Completer<bool?>();
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              resultCompleter.complete(
                await showCreateFolderDialog(
                  context,
                  api: api,
                  initialPath: initialPath,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return resultCompleter.future;
}

void main() {
  group('showCreateFolderDialog', () {
    testWidgets('reduced motion skips folder dialog animation', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      addTearDown(api.close);
      await _openDialog(tester, api: api, reducedMotion: true);
      final route = ModalRoute.of(
        tester.element(find.byKey(const Key('folder.create.input'))),
      )!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      await tester.tap(find.byKey(const Key('folder.create.cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder.create.input')), findsNothing);
    }, variant: TargetPlatformVariant.all());

    testWidgets('pre-fills the input with initialPath', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      addTearDown(api.close);

      await _openDialog(tester, api: api, initialPath: 'Projects');

      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('folder.create.input')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.controller.text, 'Projects');
    });

    testWidgets('confirming calls createFolder and pops true on success', (
      tester,
    ) async {
      Map<String, dynamic>? body;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, Object?>{'path': 'Ideas', 'note_count': 0}),
            201,
          );
        }),
      );
      addTearDown(api.close);

      final result = await _openDialog(tester, api: api);
      await tester.enterText(
        find.byKey(const Key('folder.create.input')),
        'Ideas',
      );
      await tester.tap(find.byKey(const Key('folder.create.confirm')));
      await tester.pumpAndSettle();

      expect(await result, isTrue);
      expect(body?['path'], 'Ideas');
    });

    testWidgets('cancelling pops false without calling the API', (
      tester,
    ) async {
      var called = false;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          called = true;
          return http.Response('', 500);
        }),
      );
      addTearDown(api.close);

      final result = await _openDialog(tester, api: api);
      await tester.tap(find.byKey(const Key('folder.create.cancel')));
      await tester.pumpAndSettle();

      expect(await result, isFalse);
      expect(called, isFalse);
    });

    testWidgets(
      'a failed create shows the server error and leaves the dialog open',
      (tester) async {
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient((request) async {
            return http.Response(
              jsonEncode(<String, Object?>{
                'error': 'bad_request',
                'message': 'path is required and must be a non-empty string',
              }),
              400,
            );
          }),
        );
        addTearDown(api.close);

        await _openDialog(tester, api: api);
        await tester.tap(find.byKey(const Key('folder.create.confirm')));
        await tester.pumpAndSettle();

        expect(
          find.text('path is required and must be a non-empty string'),
          findsOneWidget,
        );
        // The dialog is still up: its Cancel/Create buttons are present.
        expect(find.byKey(const Key('folder.create.confirm')), findsOneWidget);
      },
    );
  });
}
