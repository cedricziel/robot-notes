import 'package:app/src/theme/app_theme.dart';
import 'package:app/src/widgets/adaptive.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(TargetPlatform platform, WidgetBuilder builder) => MaterialApp(
  theme: AppTheme.light(platform: platform),
  home: Scaffold(body: Builder(builder: builder)),
);

void main() {
  group('useCupertino', () {
    for (final (platform, expected) in [
      (TargetPlatform.iOS, true),
      (TargetPlatform.macOS, true),
      (TargetPlatform.android, false),
      (TargetPlatform.windows, false),
      (TargetPlatform.linux, false),
    ]) {
      testWidgets('is $expected on ${platform.name}', (tester) async {
        late bool seen;
        await tester.pumpWidget(
          _host(platform, (context) {
            seen = useCupertino(context);
            return const SizedBox.shrink();
          }),
        );
        expect(seen, expected);
      });
    }
  });

  group('adaptiveDialogAction', () {
    testWidgets('is a CupertinoDialogAction on iOS', (tester) async {
      await tester.pumpWidget(
        _host(
          TargetPlatform.iOS,
          (context) => adaptiveDialogAction(
            context,
            primary: true,
            destructive: true,
            onPressed: () {},
            child: const Text('Delete'),
          ),
        ),
      );
      final action = tester.widget<CupertinoDialogAction>(
        find.byType(CupertinoDialogAction),
      );
      expect(action.isDefaultAction, isTrue);
      expect(action.isDestructiveAction, isTrue);
    });

    testWidgets('is a FilledButton for a primary action elsewhere', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          TargetPlatform.android,
          (context) => adaptiveDialogAction(
            context,
            primary: true,
            onPressed: () {},
            child: const Text('Move'),
          ),
        ),
      );
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(CupertinoDialogAction), findsNothing);
    });

    testWidgets('is a TextButton for a secondary action elsewhere', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          TargetPlatform.windows,
          (context) => adaptiveDialogAction(
            context,
            onPressed: () {},
            child: const Text('Cancel'),
          ),
        ),
      );
      expect(find.byType(TextButton), findsOneWidget);
    });
  });

  group('AdaptiveDialogTextField', () {
    testWidgets('is a CupertinoTextField on macOS and reports edits', (
      tester,
    ) async {
      final edits = <String>[];
      await tester.pumpWidget(
        _host(
          TargetPlatform.macOS,
          (_) => AdaptiveDialogTextField(
            key: const Key('field'),
            label: 'Folder path',
            hint: 'e.g. Projects',
            initialValue: 'Inbox',
            onChanged: edits.add,
          ),
        ),
      );
      final field = tester.widget<CupertinoTextField>(
        find.byType(CupertinoTextField),
      );
      expect(field.placeholder, 'e.g. Projects');
      expect(find.text('Inbox'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('field')), 'Projects');
      expect(edits, ['Projects']);
    });

    testWidgets('is a labelled Material field elsewhere', (tester) async {
      await tester.pumpWidget(
        _host(
          TargetPlatform.android,
          (_) => AdaptiveDialogTextField(
            label: 'Folder path',
            hint: 'e.g. Projects',
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.text('Folder path'), findsOneWidget);
      expect(find.byType(CupertinoTextField), findsNothing);
    });
  });

  group('AdaptiveMoreMenu', () {
    Widget menu({required VoidCallback onDelete}) => AdaptiveMoreMenu(
      key: const Key('more'),
      entries: [
        AdaptiveMenuEntry(
          key: const Key('more.delete'),
          label: 'Delete',
          destructive: true,
          onSelected: onDelete,
        ),
      ],
    );

    testWidgets('uses the platform "more" glyph', (tester) async {
      await tester.pumpWidget(
        _host(TargetPlatform.iOS, (_) => menu(onDelete: () {})),
      );
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);

      await tester.pumpWidget(
        _host(TargetPlatform.android, (_) => menu(onDelete: () {})),
      );
      // The theme change animates; let the new platform settle in.
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });

    testWidgets('on iOS runs the handler once the sheet is popped', (
      tester,
    ) async {
      var sheetRouteCurrentWhenRun = true;
      late BuildContext hostContext;
      await tester.pumpWidget(
        _host(TargetPlatform.iOS, (context) {
          hostContext = context;
          return menu(
            onDelete: () {
              // The sheet's route has been popped (it may still be
              // animating out), so a dialog opened here lands on top of
              // the page, not on top of the sheet.
              sheetRouteCurrentWhenRun =
                  ModalRoute.of(hostContext)?.isCurrent == false;
            },
          );
        }),
      );
      await tester.tap(find.byKey(const Key('more')));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(ModalRoute.of(hostContext)?.isCurrent, isFalse);

      await tester.tap(find.byKey(const Key('more.delete')));
      await tester.pumpAndSettle();

      expect(sheetRouteCurrentWhenRun, isFalse);
      expect(find.byType(CupertinoActionSheet), findsNothing);
    });

    testWidgets('on Android is a popup menu whose item runs the handler', (
      tester,
    ) async {
      var ran = false;
      await tester.pumpWidget(
        _host(TargetPlatform.android, (_) => menu(onDelete: () => ran = true)),
      );
      await tester.tap(find.byKey(const Key('more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('more.delete')));
      await tester.pumpAndSettle();

      expect(ran, isTrue);
      expect(find.byType(CupertinoActionSheet), findsNothing);
    });
  });
}
