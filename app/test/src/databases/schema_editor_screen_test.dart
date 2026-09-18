import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/schema_editor_screen.dart';
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

DatabaseDefinition _definition({int version = 3}) => DatabaseDefinition(
  id: '01D',
  title: 'Projects',
  path: 'Projects/Projects.md',
  version: version,
  source: const DatabaseSource.folder('Projects'),
  properties: {
    'status': const PropertyDefinition(
      type: PropertyType.select,
      options: ['Idea', 'Active'],
    ),
  },
  views: [const ViewDefinition(name: 'All', type: ViewType.table)],
  createdAt: DateTime.utc(2025),
  updatedAt: DateTime.utc(2025),
);

Map<String, Object?> _definitionJson(DatabaseDefinition d) => d.toJson();

void main() {
  group('SchemaEditorScreen', () {
    testWidgets('adding a property and saving sends PUT with If-Match', (
      tester,
    ) async {
      http.Request? captured;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(_definitionJson(_definition(version: 4))),
            200,
          );
        }),
      );
      addTearDown(api.close);
      DatabaseDefinition? saved;

      await tester.pumpWidget(
        MaterialApp(
          home: SchemaEditorScreen(
            definition: _definition(),
            api: api,
            onSaved: (d) => saved = d,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('schemaEditor.addProperty')));
      await tester.pumpAndSettle();

      // The newly-added row is the second property key field; the first
      // is the existing `status` property.
      final propertyKeyFinder = find.byWidgetPredicate((w) {
        if (w is! TextFormField) return false;
        final key = w.key?.toString() ?? '';
        return key.contains('schemaEditor.property') && key.contains('.key');
      });
      expect(propertyKeyFinder, findsNWidgets(2));
      await tester.enterText(propertyKeyFinder.last, 'due');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('schemaEditor.save')));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.url.path, '/databases/01D');
      expect(captured!.headers['If-Match'], '3');
      final body = jsonDecode(captured!.body) as Map<String, Object?>;
      final properties = body['properties'] as Map<String, Object?>;
      expect(properties.containsKey('status'), isTrue);
      expect(properties.containsKey('due'), isTrue);
      expect(saved?.version, 4);
    });

    testWidgets('an invalid property key disables Save', (tester) async {
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((_) async => http.Response('', 500)),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SchemaEditorScreen(
            definition: _definition(),
            api: api,
            onSaved: (_) {},
          ),
        ),
      );

      final statusKeyField = find.byWidgetPredicate(
        (w) =>
            w is TextFormField &&
            (w.key?.toString() ?? '').contains('schemaEditor.property') &&
            (w.key?.toString() ?? '').contains('.key'),
      );
      await tester.enterText(statusKeyField, 'Bad Key');
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('schemaEditor.save')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('removing a property removes it from the saved payload', (
      tester,
    ) async {
      http.Request? captured;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(_definitionJson(_definition(version: 4))),
            200,
          );
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SchemaEditorScreen(
            definition: _definition(),
            api: api,
            onSaved: (_) {},
          ),
        ),
      );

      final removeButton = find.byWidgetPredicate(
        (w) =>
            w is IconButton &&
            (w.key?.toString() ?? '').contains('schemaEditor.property') &&
            (w.key?.toString() ?? '').contains('.remove'),
      );
      await tester.tap(removeButton);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('schemaEditor.save')));
      await tester.pumpAndSettle();

      final body = jsonDecode(captured!.body) as Map<String, Object?>;
      expect((body['properties'] as Map).containsKey('status'), isFalse);
    });

    testWidgets('adding, editing, reordering and removing views', (
      tester,
    ) async {
      http.Request? captured;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(_definitionJson(_definition(version: 4))),
            200,
          );
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SchemaEditorScreen(
            definition: _definition(),
            api: api,
            onSaved: (_) {},
          ),
        ),
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('schemaEditor.addView')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('schemaEditor.addView')));
      await tester.pumpAndSettle();

      final nameFields = find.byWidgetPredicate(
        (w) =>
            w is TextFormField &&
            (w.key?.toString() ?? '').contains('schemaEditor.view') &&
            (w.key?.toString() ?? '').contains('.name'),
      );
      expect(nameFields, findsNWidgets(2));

      // Move the second view up so it becomes first, then remove the
      // (now second) original "All" view.
      final upButtons = find.byWidgetPredicate(
        (w) =>
            w is IconButton &&
            (w.key?.toString() ?? '').contains('schemaEditor.view') &&
            (w.key?.toString() ?? '').contains('.up'),
      );
      await tester.scrollUntilVisible(
        upButtons.last,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(upButtons.last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('schemaEditor.save')));
      await tester.pumpAndSettle();

      final body = jsonDecode(captured!.body) as Map<String, Object?>;
      final views = body['views'] as List<Object?>;
      expect(views.length, 2);
      expect((views.first as Map)['name'], 'View 2');
    });

    testWidgets(
      'a 409 conflict reloads via GET /databases/{id} and keeps local edits',
      (tester) async {
        var putCount = 0;
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient((request) async {
            if (request.method == 'PUT') {
              putCount++;
              return http.Response(
                jsonEncode({'error': 'version_conflict'}),
                409,
              );
            }
            return http.Response(
              jsonEncode(_definitionJson(_definition(version: 9))),
              200,
            );
          }),
        );
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: SchemaEditorScreen(
              definition: _definition(),
              api: api,
              onSaved: (_) {},
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('schemaEditor.save')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('schemaEditor.conflict')), findsOneWidget);
        expect(putCount, 1);
        // The property added before saving is still visible to edit.
        expect(find.text('status'), findsOneWidget);
      },
    );
  });
}
