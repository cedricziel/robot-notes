import 'package:app/src/databases/database_embed_syntax.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, String data) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: data,
            blockSyntaxes: const [DatabaseEmbedSyntax()],
            builders: {
              databaseEmbedTag: DatabaseEmbedBuilder(
                embedBuilder: (context, title, view) => Text(
                  'Resolved: $title${view == null ? "" : " ($view)"}',
                  key: const Key('resolved-embed'),
                ),
              ),
            },
          ),
        ),
      ),
    );
  }

  testWidgets(
    'a whole-line ![[Title#View]] is claimed and rendered by the custom '
    'builder',
    (tester) async {
      await pump(tester, '![[Projects#Board]]');

      expect(find.byKey(const Key('resolved-embed')), findsOneWidget);
      expect(find.text('Resolved: Projects (Board)'), findsOneWidget);
      expect(find.textContaining('![[Projects#Board]]'), findsNothing);
    },
  );

  testWidgets('a whole-line ![[Title]] with no view is claimed too', (
    tester,
  ) async {
    await pump(tester, '![[Projects]]');

    expect(find.byKey(const Key('resolved-embed')), findsOneWidget);
    expect(find.text('Resolved: Projects'), findsOneWidget);
  });

  testWidgets(
    'an inline ![[x]] inside a paragraph with other text renders literally, '
    'not as an embed',
    (tester) async {
      await pump(tester, 'See ![[Projects]] for details.');

      expect(find.byKey(const Key('resolved-embed')), findsNothing);
      expect(find.textContaining('![[Projects]]'), findsOneWidget);
    },
  );

  testWidgets(
    'an ordinary [[x]] wikilink (no leading !) renders literally, unaffected '
    'by the embed syntax',
    (tester) async {
      await pump(tester, '[[Projects]]');

      expect(find.byKey(const Key('resolved-embed')), findsNothing);
      expect(find.textContaining('[[Projects]]'), findsOneWidget);
    },
  );

  testWidgets('a whole-line embed preserves the following paragraph', (
    tester,
  ) async {
    await pump(tester, '![[Projects]]\n\nSome other paragraph.');

    expect(find.byKey(const Key('resolved-embed')), findsOneWidget);
    expect(find.text('Some other paragraph.'), findsOneWidget);
  });
}
