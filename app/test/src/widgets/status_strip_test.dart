import 'package:app/src/widgets/status_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ColorScheme> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    );
    return Theme.of(tester.element(find.byType(StatusStrip))).colorScheme;
  }

  Material material(WidgetTester tester) => tester.widget<Material>(
    find
        .descendant(
          of: find.byType(StatusStrip),
          matching: find.byType(Material),
        )
        .first,
  );

  Color? textColor(WidgetTester tester, String message) =>
      tester.widget<Text>(find.text(message)).style?.color;

  testWidgets('renders the message on the info container by default', (
    tester,
  ) async {
    final scheme = await pump(
      tester,
      const StatusStrip(key: Key('strip'), message: 'Saved'),
    );

    expect(find.byKey(const Key('strip')), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(material(tester).color, scheme.surfaceContainerHighest);
    expect(textColor(tester, 'Saved'), scheme.onSurface);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('warning tone uses the secondary container pair', (tester) async {
    final scheme = await pump(
      tester,
      const StatusStrip(message: 'Reconnecting…', tone: StatusTone.warning),
    );

    expect(material(tester).color, scheme.secondaryContainer);
    expect(textColor(tester, 'Reconnecting…'), scheme.onSecondaryContainer);
  });

  testWidgets('error tone uses the error container pair and tints the icon', (
    tester,
  ) async {
    final scheme = await pump(
      tester,
      const StatusStrip(
        message: 'Failed',
        tone: StatusTone.error,
        icon: Icons.error_outline,
      ),
    );

    expect(material(tester).color, scheme.errorContainer);
    expect(textColor(tester, 'Failed'), scheme.onErrorContainer);
    final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
    expect(icon.color, scheme.onErrorContainer);
  });

  testWidgets('a leading widget takes precedence over the icon', (
    tester,
  ) async {
    await pump(
      tester,
      const StatusStrip(
        message: 'Working',
        icon: Icons.error_outline,
        leading: SizedBox(key: Key('lead'), width: 18, height: 18),
      ),
    );

    expect(find.byKey(const Key('lead')), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('renders the trailing action and it stays tappable', (
    tester,
  ) async {
    var tapped = false;
    await pump(
      tester,
      StatusStrip(
        message: 'Could not load',
        tone: StatusTone.error,
        action: TextButton(
          onPressed: () => tapped = true,
          child: const Text('Retry'),
        ),
      ),
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(tapped, isTrue);
    // The action sits after the message.
    expect(
      tester.getTopLeft(find.text('Retry')).dx,
      greaterThan(tester.getTopLeft(find.text('Could not load')).dx),
    );
  });

  testWidgets('rounded gives the surface a radius; dense shrinks its height', (
    tester,
  ) async {
    await pump(tester, const StatusStrip(message: 'A'));
    final plainHeight = tester.getSize(find.byType(StatusStrip)).height;
    expect(material(tester).borderRadius, isNull);

    await pump(tester, const StatusStrip(message: 'A', rounded: true));
    expect(material(tester).borderRadius, BorderRadius.circular(8));

    await pump(tester, const StatusStrip(message: 'A', dense: true));
    expect(
      tester.getSize(find.byType(StatusStrip)).height,
      lessThan(plainHeight),
    );
  });

  testWidgets('a long message wraps instead of overflowing', (tester) async {
    await pump(
      tester,
      StatusStrip(
        message: 'This message is long enough that it must wrap ' * 4,
        icon: Icons.info_outline,
        action: TextButton(onPressed: () {}, child: const Text('OK')),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
