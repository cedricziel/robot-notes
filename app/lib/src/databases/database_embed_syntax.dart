import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// Markdown tag emitted by [DatabaseEmbedSyntax] for a whole-line
/// `![[Title]]` / `![[Title#View]]` embed, consumed by
/// [DatabaseEmbedBuilder].
const String databaseEmbedTag = 'databaseEmbed';

/// A [md.BlockSyntax] that claims a whole line matching
/// `![[Title]]` or `![[Title#View]]` and turns it into a
/// `<databaseEmbed title="..." view="...">` element instead of the default
/// paragraph/text handling.
///
/// Confirmed via the widget-test spike in
/// `test/src/databases/database_embed_syntax_spike_test.dart`: a custom
/// [md.BlockSyntax] registered through [MarkdownBody.blockSyntaxes] can
/// claim an entire line and hand it to a [MarkdownElementBuilder]
/// registered under the same tag in [MarkdownBody.builders], without
/// touching how inline `![[...]]` (inside a paragraph) or plain `[[...]]`
/// text renders elsewhere — see design.md, "Decisions", for the full
/// write-up of the API shape and gotchas found here.
class DatabaseEmbedSyntax extends md.BlockSyntax {
  const DatabaseEmbedSyntax();

  // Whole-line only: anchored start-to-end, so `![[Title]]` sitting inside
  // a paragraph with other text (or preceded/followed by anything else on
  // the same line) does not match and falls through to normal inline
  // parsing instead.
  static final RegExp _pattern = RegExp(r'^!\[\[(.+?)(?:#(.+?))?\]\]\s*$');

  @override
  RegExp get pattern => _pattern;

  @override
  md.Node? parse(md.BlockParser parser) {
    final match = _pattern.firstMatch(parser.current.content);
    parser.advance();
    if (match == null) return null;
    final element = md.Element.empty(databaseEmbedTag);
    element.attributes['title'] = match[1]!.trim();
    final view = match[2]?.trim();
    if (view != null && view.isNotEmpty) {
      element.attributes['view'] = view;
    }
    return element;
  }
}

/// Renders the `<databaseEmbed>` element [DatabaseEmbedSyntax] produces.
///
/// With no [embedBuilder] this is the task-1.1 spike's proof-of-concept
/// placeholder (`Database: <title>`-style text in a bordered box), kept as
/// the default so `database_embed_syntax_spike_test.dart` keeps exercising
/// the bare block-syntax/builder wiring. The real embed (`DatabaseEmbed`,
/// task 7.2, in `database_embed.dart`) is wired in via [embedBuilder] by
/// its callers (the note view's view-mode `MarkdownBody` and edit-mode
/// preview `Markdown`), replacing the placeholder body with the resolved,
/// read-only view rendering.
class DatabaseEmbedBuilder extends MarkdownElementBuilder {
  DatabaseEmbedBuilder({this.embedBuilder});

  /// Builds the real embed widget for a resolved `title`/`view` pair.
  /// `null` keeps the placeholder rendering.
  final Widget Function(BuildContext context, String title, String? view)?
  embedBuilder;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final title = element.attributes['title'] ?? '';
    final view = element.attributes['view'];
    final builder = embedBuilder;
    if (builder != null) return builder(context, title, view);
    return Container(
      key: Key('database-embed-$title${view == null ? '' : '#$view'}'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        view == null ? 'Database: $title' : 'Database: $title (view: $view)',
      ),
    );
  }
}
