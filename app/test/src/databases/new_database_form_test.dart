import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/new_database_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

Map<String, Object?> _definitionJson({int version = 1}) => <String, Object?>{
  'id': '01D',
  'title': 'Projects',
  'path': 'Projects/Projects.md',
  'version': version,
  'source': <String, Object?>{'folder': 'Projects', 'include_subfolders': true},
  'properties': <String, Object?>{
    'status': <String, Object?>{
      'type': 'select',
      'options': ['Idea', 'Active'],
    },
  },
  'views': <Object?>[
    <String, Object?>{'name': 'All', 'type': 'table'},
  ],
  'created_at': '2025-01-01T00:00:00.000Z',
  'updated_at': '2025-01-01T00:00:00.000Z',
};

void main() {
  group('NewDatabaseForm', () {
    testWidgets('submitting posts to POST /databases and calls onCreated', (
      tester,
    ) async {
      http.Request? captured;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode(_definitionJson()), 201);
        }),
      );
      addTearDown(api.close);
      DatabaseDefinition? created;

      await tester.pumpWidget(
        MaterialApp(
          home: NewDatabaseForm(api: api, onCreated: (d) => created = d),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('newDatabase.title')),
        'Projects',
      );
      await tester.enterText(
        find.byKey(const Key('newDatabase.folder')),
        'Projects',
      );
      await tester.enterText(
        find.byKey(const Key('newDatabase.property.0.key')),
        'status',
      );
      await tester.enterText(
        find.byKey(const Key('newDatabase.view.name')),
        'All',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('newDatabase.submit')));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.url.path, '/databases');
      final body = jsonDecode(captured!.body) as Map<String, Object?>;
      expect(body['title'], 'Projects');
      expect((body['source'] as Map)['folder'], 'Projects');
      // Default property type (no dropdown interaction needed): text.
      expect((body['properties'] as Map)['status'], {'type': 'text'});
      expect((body['views'] as List).single, {'name': 'All', 'type': 'table'});
      expect(created?.id, '01D');
    });

    testWidgets('selecting the select type reveals an options field', (
      tester,
    ) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((_) async => http.Response('', 500)),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: NewDatabaseForm(api: api, onCreated: (_) {}),
        ),
      );

      expect(
        find.byKey(const Key('newDatabase.property.0.options')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('newDatabase.property.0.type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('select').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('newDatabase.property.0.options')),
        findsOneWidget,
      );
    });

    testWidgets('a 400 validation error stays open and shows the message', (
      tester,
    ) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': 'validation_failed',
              'message': 'status: unknown option',
            }),
            400,
          ),
        ),
      );
      addTearDown(api.close);
      var created = false;

      await tester.pumpWidget(
        MaterialApp(
          home: NewDatabaseForm(api: api, onCreated: (_) => created = true),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('newDatabase.title')),
        'Projects',
      );
      await tester.enterText(
        find.byKey(const Key('newDatabase.view.name')),
        'All',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('newDatabase.submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('newDatabase.error')), findsOneWidget);
      expect(find.text('status: unknown option'), findsOneWidget);
      expect(created, isFalse);
      // The form is still there to retry from.
      expect(find.byKey(const Key('newDatabase.submit')), findsOneWidget);
    });

    testWidgets('an invalid property key disables Create', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((_) async => http.Response('', 500)),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: NewDatabaseForm(api: api, onCreated: (_) {}),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('newDatabase.title')),
        'Projects',
      );
      await tester.enterText(
        find.byKey(const Key('newDatabase.property.0.key')),
        'Due Date',
      );
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('newDatabase.submit')),
      );
      expect(button.onPressed, isNull);
    });
  });
}
