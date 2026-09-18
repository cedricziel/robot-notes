import 'package:app/src/widgets/empty_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('renders the icon, title, message and action', (tester) async {
    var tapped = false;
    await pump(
      tester,
      EmptyState(
        key: const Key('empty'),
        icon: Icons.inbox_outlined,
        title: 'Nothing here',
        message: 'Try something else.',
        action: FilledButton.tonal(
          onPressed: () => tapped = true,
          child: const Text('Do it'),
        ),
      ),
    );

    expect(find.byKey(const Key('empty')), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Try something else.'), findsOneWidget);

    await tester.tap(find.text('Do it'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('omits the message and action when not supplied', (tester) async {
    await pump(
      tester,
      const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing here'),
    );

    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.byType(ButtonStyleButton), findsNothing);
    // Only the title Text is rendered.
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('centers its content and styles the title as titleMedium', (
    tester,
  ) async {
    await pump(
      tester,
      const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing here'),
    );

    final title = find.text('Nothing here');
    final theme = Theme.of(tester.element(title));
    final style = tester.widget<Text>(title).style;
    expect(style?.fontSize, theme.textTheme.titleMedium?.fontSize);

    final screen = tester.getSize(find.byType(Scaffold));
    final center = tester.getCenter(find.byType(EmptyState));
    expect(center.dx, closeTo(screen.width / 2, 1));
    expect(tester.getCenter(title).dx, closeTo(screen.width / 2, 1));
  });

  testWidgets('wraps long text inside a narrow box', (tester) async {
    await pump(
      tester,
      Center(
        child: SizedBox(
          width: 240,
          height: 560,
          child: EmptyState(
            icon: Icons.inbox_outlined,
            title: 'A rather long title that has to wrap onto lines',
            message: 'And an even longer explanation ' * 2,
            action: FilledButton.tonal(
              onPressed: () {},
              child: const Text('Action'),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // Text stays within the box horizontally rather than overflowing it.
    final box = tester.getRect(find.byType(SizedBox).first);
    for (final text in find.byType(Text).evaluate()) {
      final rect = tester.getRect(find.byWidget(text.widget));
      expect(rect.left, greaterThanOrEqualTo(box.left));
      expect(rect.right, lessThanOrEqualTo(box.right));
    }
  });
}
