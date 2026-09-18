import 'package:app/src/databases/property_value_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('PropertyValueView.tags', () {
    testWidgets('renders one chip per tag', (tester) async {
      await _pump(tester, const PropertyValueView.tags(['work', 'urgent']));

      expect(
        find.byKey(const Key('property_value_view.tag.work')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('property_value_view.tag.urgent')),
        findsOneWidget,
      );
    });

    testWidgets('renders nothing visible for no tags', (tester) async {
      await _pump(tester, const PropertyValueView.tags([]));

      expect(find.byType(Chip), findsNothing);
    });
  });

  group('PropertyValueView.relativeTime', () {
    testWidgets(
      'renders relative time with the absolute timestamp as a tooltip',
      (tester) async {
        final now = DateTime.now();
        final ts = now.subtract(const Duration(hours: 3));
        await _pump(tester, PropertyValueView.relativeTime(ts));

        final text = tester.widget<Text>(
          find.byKey(const Key('property_value_view.relative_time')),
        );
        expect(text.data, contains('hour'));
        expect(find.byType(Tooltip), findsOneWidget);
      },
    );
  });

  group('PropertyValueView.path', () {
    testWidgets('renders the path as plain text', (tester) async {
      await _pump(tester, const PropertyValueView.path('Projects/Alpha.md'));

      expect(find.text('Projects/Alpha.md'), findsOneWidget);
    });
  });

  group('PropertyValueView.unrepresentable', () {
    testWidgets('renders a null value as an em dash', (tester) async {
      await _pump(tester, const PropertyValueView.unrepresentable(null));

      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('renders a list value joined by commas', (tester) async {
      await _pump(
        tester,
        const PropertyValueView.unrepresentable(['a', 'b', 'c']),
      );

      expect(find.text('a, b, c'), findsOneWidget);
    });

    testWidgets('renders a scalar value via toString', (tester) async {
      await _pump(tester, const PropertyValueView.unrepresentable(42));

      expect(find.text('42'), findsOneWidget);
    });
  });
}
