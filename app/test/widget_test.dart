import 'package:app/main.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('boots into the splash while configuration loads', (
    tester,
  ) async {
    await tester.pumpWidget(const RobotNotesApp());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
