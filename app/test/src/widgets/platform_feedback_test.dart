import 'package:app/src/widgets/platform_feedback.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

void main() {
  testWidgets(
    'desktop results replace stale feedback and can be dismissed',
    (tester) async {
      late PlatformFeedback feedback;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: defaultTargetPlatform),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                feedback = PlatformFeedback.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      feedback.show('Saved (v2)');
      await tester.pumpAndSettle();
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).width, 420);
      feedback.show('Note moved');
      await tester.pumpAndSettle();
      expect(find.text('Saved (v2)'), findsNothing);
      expect(find.text('Note moved'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Note moved'), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'iOS results appear inline with an accessible error announcement',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        late PlatformFeedback feedback;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  feedback = PlatformFeedback.of(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );
        feedback.show('Could not save', error: true);
        await tester.pumpAndSettle();
        final bar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(bar.behavior, SnackBarBehavior.fixed);
        expect(
          tester
              .getSemantics(find.text('Could not save'))
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        expect(find.text('Could not save'), findsOneWidget);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.text('Could not save'), findsNothing);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('reduced-motion feedback has no entrance or exit transition', (
    tester,
  ) async {
    late PlatformFeedback feedback;
    late ScaffoldMessengerState messenger;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              feedback = PlatformFeedback.of(context);
              messenger = ScaffoldMessenger.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    feedback.show('Note deleted');
    await tester.pump();
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).animation!.value, 1);
    messenger.hideCurrentSnackBar();
    await tester.pump();
    expect(find.text('Note deleted'), findsNothing);
  }, variant: TargetPlatformVariant.all());

  testWidgets('desktop notification fits a narrow pane and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late PlatformFeedback feedback;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              feedback = PlatformFeedback.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    feedback.show('Uploaded a-very-long-file-name-with-spaces.png');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('Uploaded a-very-long-file-name-with-spaces.png'),
      findsOneWidget,
    );
  });
  testWidgets(
    'captured feedback survives closing the note route',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      body: Builder(
                        builder: (context) {
                          final feedback = PlatformFeedback.of(context);
                          return TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              feedback.show('Note deleted');
                            },
                            child: const Text('Delete note'),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                child: const Text('Open note'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete note'));
      await tester.pumpAndSettle();
      expect(find.text('Open note'), findsOneWidget);
      expect(find.text('Delete note'), findsNothing);
      expect(find.text('Note deleted'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
