import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/widgets/connection_banner.dart';
import 'package:app/src/widgets/status_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ValueNotifier<ConnectionStatus> status;

  setUp(() {
    status = ValueNotifier<ConnectionStatus>(ConnectionStatus.connected);
    addTearDown(status.dispose);
  });

  Future<void> pumpBanner(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ConnectionBanner(status: status)),
    ),
  );

  testWidgets('renders nothing while connected', (tester) async {
    await pumpBanner(tester);

    expect(find.byKey(const Key('connection.banner')), findsNothing);
  });

  testWidgets('shows a strip per offline state and hides it on reconnect', (
    tester,
  ) async {
    await pumpBanner(tester);

    status.value = ConnectionStatus.reconnecting;
    await tester.pump();
    expect(find.text('Reconnecting…'), findsOneWidget);

    status.value = ConnectionStatus.stale;
    await tester.pump();
    expect(find.text('Reconnecting…'), findsNothing);
    expect(find.text('Connection lost — showing cached notes'), findsOneWidget);

    status.value = ConnectionStatus.connected;
    await tester.pump();
    expect(find.byKey(const Key('connection.banner')), findsNothing);
  });

  testWidgets('the visible strip is a dense StatusStrip inside a SafeArea', (
    tester,
  ) async {
    status.value = ConnectionStatus.reconnecting;
    await pumpBanner(tester);

    final strip = find.byKey(const Key('connection.banner'));
    expect(strip, findsOneWidget);
    expect(tester.widget<StatusStrip>(strip).dense, isTrue);
    expect(tester.widget<StatusStrip>(strip).tone, StatusTone.warning);
    expect(
      find.ancestor(of: strip, matching: find.byType(SafeArea)),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SafeArea>(
            find.ancestor(of: strip, matching: find.byType(SafeArea)),
          )
          .bottom,
      isFalse,
    );

    status.value = ConnectionStatus.stale;
    await tester.pump();
    expect(tester.widget<StatusStrip>(strip).tone, StatusTone.error);
    expect(
      find.ancestor(of: strip, matching: find.byType(SafeArea)),
      findsOneWidget,
    );
  });

  testWidgets('the strip is inset below the status bar on phones', (
    tester,
  ) async {
    status.value = ConnectionStatus.stale;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(top: 44)),
        child: MaterialApp(
          home: Scaffold(body: ConnectionBanner(status: status)),
        ),
      ),
    );

    final top = tester.getTopLeft(find.byKey(const Key('connection.banner')));
    expect(top.dy, 44);
  });

  testWidgets('no SafeArea is reserved while connected', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(top: 44)),
        child: MaterialApp(
          home: Scaffold(body: ConnectionBanner(status: status)),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(ConnectionBanner),
        matching: find.byType(SafeArea),
      ),
      findsNothing,
    );
    expect(tester.getSize(find.byType(ConnectionBanner)), Size.zero);
  });
}
