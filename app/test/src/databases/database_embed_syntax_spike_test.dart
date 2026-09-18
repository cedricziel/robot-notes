import 'package:app/src/databases/database_embed_syntax.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spike for task 1.1: proves flutter_markdown_plus's custom
/// `BlockSyntax` + `MarkdownElementBuilder` API can claim a whole line
/// `![[Title#View]]` and render a custom widget for it, while an inline
/// `![[x]]` sitting inside a paragraph, and an ordinary `[[x]]`, keep
/// rendering as literal text — exactly as the design's embed decision
/// requires.
void main() {
  Future<void> pump(WidgetTester tester, String data) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: data,
            blockSyntaxes: const [DatabaseEmbedSyntax()],
            builders: {databaseEmbedTag: DatabaseEmbedBuilder()},
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

      expect(
        find.byKey(const Key('database-embed-Projects#Board')),
        findsOneWidget,
      );
      expect(find.text('Database: Projects (view: Board)'), findsOneWidget);
      // The literal markdown source must not leak through as plain text.
      expect(find.textContaining('![[Projects#Board]]'), findsNothing);
    },
  );

  testWidgets('a whole-line ![[Title]] with no view is claimed too', (
    tester,
  ) async {
    await pump(tester, '![[Projects]]');

    expect(find.byKey(const Key('database-embed-Projects')), findsOneWidget);
    expect(find.text('Database: Projects'), findsOneWidget);
  });

  testWidgets(
    'an inline ![[x]] inside a paragraph with other text renders literally, '
    'not as an embed',
    (tester) async {
      await pump(tester, 'See ![[Projects]] for details.');

      expect(find.byType(Container), findsNothing);
      // Rendered as plain text: the paragraph text widget contains the
      // literal wikilink-embed syntax untouched.
      expect(find.textContaining('![[Projects]]'), findsOneWidget);
    },
  );

  testWidgets(
    'an ordinary [[x]] wikilink (no leading !) renders literally, unaffected '
    'by the embed syntax',
    (tester) async {
      await pump(tester, '[[Projects]]');

      expect(find.byType(Container), findsNothing);
      expect(find.textContaining('[[Projects]]'), findsOneWidget);
    },
  );

  testWidgets(
    'an inline ![[x]] on its own paragraph but followed by more text on the '
    'next line stays literal for that line while a genuinely bare line is '
    'still claimed',
    (tester) async {
      await pump(tester, '![[Projects]]\n\nSome other paragraph.');

      expect(find.byKey(const Key('database-embed-Projects')), findsOneWidget);
      expect(find.text('Some other paragraph.'), findsOneWidget);
    },
  );
}
