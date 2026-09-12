import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/widgets/connection_banner.dart';
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
}
