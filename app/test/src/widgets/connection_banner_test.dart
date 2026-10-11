import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/widgets/connection_banner.dart';
import 'package:material_ui/material_ui.dart';
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

  testWidgets('shows a reconnecting message while reconnecting', (
    tester,
  ) async {
    status.value = ConnectionStatus.reconnecting;
    await pumpBanner(tester);

    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);
  });

  testWidgets('shows cached-note warning when the connection is stale', (
    tester,
  ) async {
    status.value = ConnectionStatus.stale;
    await pumpBanner(tester);

    expect(find.text('Connection lost — showing cached notes'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
  });

  testWidgets('removes the warning when the connection recovers', (
    tester,
  ) async {
    status.value = ConnectionStatus.stale;
    await pumpBanner(tester);

    status.value = ConnectionStatus.connected;
    await tester.pump();

    expect(find.text('Connection lost — showing cached notes'), findsNothing);
    expect(tester.getSize(find.byType(ConnectionBanner)), Size.zero);
  });

  testWidgets('the strip is inset below the status bar on phones', (
    tester,
  ) async {
    status.value = ConnectionStatus.stale;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(top: 44, bottom: 34),
        ),
        child: MaterialApp(
          home: Scaffold(body: ConnectionBanner(status: status)),
        ),
      ),
    );

    final top = tester.getTopLeft(find.byKey(const Key('connection.banner')));
    expect(top.dy, 44);
    expect(
      tester.getSize(find.byType(ConnectionBanner)).height,
      tester.getSize(find.byKey(const Key('connection.banner'))).height + 44,
    );
  });

  testWidgets('reserves no space while connected despite system insets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(top: 44, bottom: 34),
        ),
        child: MaterialApp(
          home: Scaffold(body: ConnectionBanner(status: status)),
        ),
      ),
    );

    expect(tester.getSize(find.byType(ConnectionBanner)), Size.zero);
  });
}
