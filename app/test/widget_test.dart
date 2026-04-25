import 'package:app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smoke test: the app boots and the placeholder home screen renders.
/// Section 20 onward will replace this with real screen-level coverage.
void main() {
  testWidgets('renders the placeholder home', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: RobotNotesApp()));

    expect(find.text('robot-notes'), findsAtLeastNWidgets(1));
    expect(
      find.text('robot-notes app scaffold (MVP build in progress)'),
      findsOneWidget,
    );
  });
}
