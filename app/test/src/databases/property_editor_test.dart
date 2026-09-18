import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/property_editor.dart';
import 'package:app/src/databases/title_search_service.dart';
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

Future<void> _pump(
  WidgetTester tester, {
  required String propertyKey,
  required PropertyDefinition definition,
  required Object? value,
  required PropertyCommitCallback onCommit,
  TitleSearchService? titleSearchService,
  bool invalid = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PropertyEditor(
          propertyKey: propertyKey,
          definition: definition,
          value: value,
          onCommit: onCommit,
          titleSearchService: titleSearchService,
          invalid: invalid,
        ),
      ),
    ),
  );
}

void main() {
  group('PropertyEditor text', () {
    testWidgets('submitting a value commits a set patch', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'summary',
        definition: const PropertyDefinition(type: PropertyType.text),
        value: null,
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.enterText(
        find.byKey(const Key('property_editor.text.field')),
        'Hello',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(sent?.set, {'summary': 'Hello'});
      expect(sent?.unset, isNull);
    });

    testWidgets('clearing the field commits unset', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'summary',
        definition: const PropertyDefinition(type: PropertyType.text),
        value: 'existing',
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.enterText(
        find.byKey(const Key('property_editor.text.field')),
        '',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(sent?.unset, ['summary']);
      expect(sent?.set, isNull);
    });

    testWidgets('a validation_failed rejection reverts and shows the message', (
      tester,
    ) async {
      await _pump(
        tester,
        propertyKey: 'summary',
        definition: const PropertyDefinition(type: PropertyType.text),
        value: 'old',
        onCommit: (p) async => 'summary must be shorter',
      );

      await tester.enterText(
        find.byKey(const Key('property_editor.text.field')),
        'a very long summary',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('summary must be shorter'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('property_editor.text.field')),
      );
      expect(field.controller!.text, 'old');
    });
  });

  group('PropertyEditor url', () {
    testWidgets('submitting commits a set patch', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'website',
        definition: const PropertyDefinition(type: PropertyType.url),
        value: null,
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.enterText(
        find.byKey(const Key('property_editor.url.field')),
        'https://example.com',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(sent?.set, {'website': 'https://example.com'});
    });
  });

  group('PropertyEditor number', () {
    testWidgets('submitting a numeric value commits a set patch', (
      tester,
    ) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'count',
        definition: const PropertyDefinition(type: PropertyType.number),
        value: null,
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.enterText(
        find.byKey(const Key('property_editor.number.field')),
        '42',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(sent?.set, {'count': 42});
    });

    testWidgets('clearing commits unset', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'count',
        definition: const PropertyDefinition(type: PropertyType.number),
        value: 3,
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.enterText(
        find.byKey(const Key('property_editor.number.field')),
        '',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(sent?.unset, ['count']);
    });

    testWidgets(
      'an unparseable value shows a local error and commits nothing',
      (tester) async {
        var called = false;
        await _pump(
          tester,
          propertyKey: 'count',
          definition: const PropertyDefinition(type: PropertyType.number),
          value: null,
          onCommit: (p) async {
            called = true;
            return null;
          },
        );

        await tester.enterText(
          find.byKey(const Key('property_editor.number.field')),
          'not a number',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(called, isFalse);
        expect(find.text('Enter a valid number.'), findsOneWidget);
      },
    );
  });

  group('PropertyEditor checkbox', () {
    testWidgets('toggling commits a set patch', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'done',
        definition: const PropertyDefinition(type: PropertyType.checkbox),
        value: false,
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.tap(find.byKey(const Key('property_editor.checkbox')));
      await tester.pumpAndSettle();

      expect(sent?.set, {'done': true});
    });
  });

  group('PropertyEditor date', () {
    testWidgets('shows the value and a clear button', (tester) async {
      await _pump(
        tester,
        propertyKey: 'due',
        definition: const PropertyDefinition(type: PropertyType.date),
        value: '2026-01-15',
        onCommit: (p) async => null,
      );

      expect(find.text('2026-01-15'), findsOneWidget);
      expect(
        find.byKey(const Key('property_editor.date.clear')),
        findsOneWidget,
      );
    });

    testWidgets('clearing commits unset', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'due',
        definition: const PropertyDefinition(type: PropertyType.date),
        value: '2026-01-15',
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.tap(find.byKey(const Key('property_editor.date.clear')));
      await tester.pumpAndSettle();

      expect(sent?.unset, ['due']);
    });

    testWidgets('no clear button when unset', (tester) async {
      await _pump(
        tester,
        propertyKey: 'due',
        definition: const PropertyDefinition(type: PropertyType.date),
        value: null,
        onCommit: (p) async => null,
      );

      expect(find.text('No date'), findsOneWidget);
      expect(find.byKey(const Key('property_editor.date.clear')), findsNothing);
    });
  });

  group('PropertyEditor select', () {
    testWidgets('picking an option commits a set patch', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'status',
        definition: const PropertyDefinition(
          type: PropertyType.select,
          options: ['Idea', 'Active', 'Done'],
        ),
        value: 'Idea',
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.tap(find.byKey(const Key('property_editor.select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Active').last);
      await tester.pumpAndSettle();

      expect(sent?.set, {'status': 'Active'});
    });

    testWidgets('picking None commits unset', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'status',
        definition: const PropertyDefinition(
          type: PropertyType.select,
          options: ['Idea', 'Active', 'Done'],
        ),
        value: 'Idea',
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.tap(find.byKey(const Key('property_editor.select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('None').last);
      await tester.pumpAndSettle();

      expect(sent?.unset, ['status']);
    });
  });

  group('PropertyEditor multi_select', () {
    testWidgets('selecting an option commits the full list', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'tags',
        definition: const PropertyDefinition(
          type: PropertyType.multiSelect,
          options: ['Red', 'Green', 'Blue'],
        ),
        value: const ['Red'],
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.tap(
        find.byKey(const Key('property_editor.multi_select.chip.Green')),
      );
      await tester.pumpAndSettle();

      expect((sent?.set?['tags'] as List).toSet(), {'Red', 'Green'});
    });

    testWidgets('deselecting the last option commits unset', (tester) async {
      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'tags',
        definition: const PropertyDefinition(
          type: PropertyType.multiSelect,
          options: ['Red', 'Green'],
        ),
        value: const ['Red'],
        onCommit: (p) async {
          sent = p;
          return null;
        },
      );

      await tester.tap(
        find.byKey(const Key('property_editor.multi_select.chip.Red')),
      );
      await tester.pumpAndSettle();

      expect(sent?.unset, ['tags']);
    });
  });

  group('PropertyEditor relation', () {
    RobotNotesClient buildApi(
      Future<http.Response> Function(http.Request) handler,
    ) => RobotNotesClient(config: _config, httpClient: MockClient(handler));

    testWidgets(
      'typing searches and selecting adds a chip, committing the list',
      (tester) async {
        final api = buildApi((request) async {
          return http.Response(
            '{"items": [{"id": "01P", "title": "Projects", "snippet": "", '
            '"rank": 1.0, "updated_at": "2026-01-01T00:00:00Z"}]}',
            200,
          );
        });
        addTearDown(api.close);
        final service = TitleSearchService(api: api);

        PropertyPatch? sent;
        await _pump(
          tester,
          propertyKey: 'related',
          definition: const PropertyDefinition(type: PropertyType.relation),
          value: const <String>[],
          onCommit: (p) async {
            sent = p;
            return null;
          },
          titleSearchService: service,
        );

        await tester.enterText(
          find.byKey(const Key('property_editor.relation.input')),
          'Pro',
        );
        await tester.pumpAndSettle();

        expect(find.text('Projects'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('property_editor.relation.suggestion.Projects')),
        );
        await tester.pumpAndSettle();

        expect(sent?.set, {
          'related': ['Projects'],
        });
      },
    );

    testWidgets('removing the last chip commits unset', (tester) async {
      final api = buildApi(
        (request) async => http.Response('{"items":[]}', 200),
      );
      addTearDown(api.close);

      PropertyPatch? sent;
      await _pump(
        tester,
        propertyKey: 'related',
        definition: const PropertyDefinition(type: PropertyType.relation),
        value: const ['Projects'],
        onCommit: (p) async {
          sent = p;
          return null;
        },
        titleSearchService: TitleSearchService(api: api),
      );

      expect(
        find.byKey(const Key('property_editor.relation.chip.Projects')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Remove Projects'));
      await tester.pumpAndSettle();

      expect(sent?.unset, ['related']);
    });
  });

  group('PropertyEditor invalid styling', () {
    testWidgets('invalid renders error-styled border', (tester) async {
      await _pump(
        tester,
        propertyKey: 'status',
        definition: const PropertyDefinition(
          type: PropertyType.select,
          options: ['Idea'],
        ),
        value: 'garbage',
        onCommit: (p) async => null,
        invalid: true,
      );

      final decorated = tester.widgetList<DecoratedBox>(
        find.byType(DecoratedBox),
      );
      expect(
        decorated.any((d) {
          final decoration = d.decoration;
          return decoration is BoxDecoration && decoration.border != null;
        }),
        isTrue,
      );
    });
  });
}
