import 'package:app/src/notes/note_property_panel.dart';
import 'package:app/src/notes/property_panel_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

DatabaseDefinition _definition({
  required Map<String, PropertyDefinition> properties,
  String id = 'db1',
  String title = 'Projects',
}) {
  final now = DateTime.utc(2025);
  return DatabaseDefinition(
    id: id,
    title: title,
    version: 1,
    source: const DatabaseSource.folder('Projects'),
    properties: properties,
    views: const [],
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Map<String, Object?> properties,
  required List<DatabaseDefinition> coveringDefinitions,
  required NotePropertyCommit onCommit,
  PropertyPanelPrefs? prefs,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: NotePropertyPanel(
          properties: properties,
          coveringDefinitions: coveringDefinitions,
          onCommit: onCommit,
          prefs: prefs ?? InMemoryPropertyPanelPrefs(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('NotePropertyPanel', () {
    testWidgets('declared properties use typed editors in definition order', (
      tester,
    ) async {
      final def = _definition(
        properties: {
          'status': const PropertyDefinition(
            type: PropertyType.select,
            options: ['todo', 'done'],
          ),
          'due': const PropertyDefinition(type: PropertyType.date),
        },
      );
      await _pump(
        tester,
        properties: {'status': 'todo', 'due': '2025-01-01'},
        coveringDefinitions: [def],
        onCommit: (key, patch) async => null,
      );

      expect(
        find.byKey(const Key('note.propertyPanel.property.status')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('property_editor.select')), findsOneWidget);
      expect(
        find.byKey(const Key('note.propertyPanel.property.due')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('property_editor.date.field')),
        findsOneWidget,
      );

      // Definition order: status appears above due.
      final statusOffset = tester
          .getTopLeft(
            find.byKey(const Key('note.propertyPanel.property.status')),
          )
          .dy;
      final dueOffset = tester
          .getTopLeft(find.byKey(const Key('note.propertyPanel.property.due')))
          .dy;
      expect(statusOffset, lessThan(dueOffset));
    });

    testWidgets('undeclared properties render read-only key/value', (
      tester,
    ) async {
      await _pump(
        tester,
        properties: {'custom_field': 'hello'},
        coveringDefinitions: const [],
        onCommit: (key, patch) async => null,
      );

      expect(
        find.byKey(const Key('note.propertyPanel.undeclared.custom_field')),
        findsOneWidget,
      );
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('committing a declared property calls onCommit with the key', (
      tester,
    ) async {
      String? committedKey;
      PropertyPatch? committedPatch;
      final def = _definition(
        properties: {
          'status': const PropertyDefinition(
            type: PropertyType.select,
            options: ['todo', 'done'],
          ),
        },
      );
      await _pump(
        tester,
        properties: {'status': 'todo'},
        coveringDefinitions: [def],
        onCommit: (key, patch) async {
          committedKey = key;
          committedPatch = patch;
          return null;
        },
      );

      await tester.tap(find.byKey(const Key('property_editor.select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('done').last);
      await tester.pumpAndSettle();

      expect(committedKey, 'status');
      expect(committedPatch!.set, {'status': 'done'});
    });

    testWidgets('collapsing hides the properties and persists the state', (
      tester,
    ) async {
      final prefs = InMemoryPropertyPanelPrefs();
      final def = _definition(
        properties: {
          'status': const PropertyDefinition(type: PropertyType.text),
        },
      );
      await _pump(
        tester,
        properties: {'status': 'todo'},
        coveringDefinitions: [def],
        onCommit: (key, patch) async => null,
        prefs: prefs,
      );

      expect(
        find.byKey(const Key('property_editor.text.field')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('note.propertyPanel.toggle')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('property_editor.text.field')), findsNothing);
      expect(await prefs.readCollapsed(), isTrue);
    });

    testWidgets('collapsed state is remembered per device on mount', (
      tester,
    ) async {
      final prefs = InMemoryPropertyPanelPrefs(collapsed: true);
      final def = _definition(
        properties: {
          'status': const PropertyDefinition(type: PropertyType.text),
        },
      );
      await _pump(
        tester,
        properties: {'status': 'todo'},
        coveringDefinitions: [def],
        onCommit: (key, patch) async => null,
        prefs: prefs,
      );

      expect(find.byKey(const Key('property_editor.text.field')), findsNothing);
    });

    testWidgets('renders nothing when there are no properties', (tester) async {
      await _pump(
        tester,
        properties: const {},
        coveringDefinitions: const [],
        onCommit: (key, patch) async => null,
      );

      expect(find.byKey(const Key('note.propertyPanel')), findsNothing);
    });
  });
}
