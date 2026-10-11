import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// Markdown tag emitted by [DatabaseEmbedSyntax] for a whole-line
/// `![[Title]]` / `![[Title#View]]` embed, consumed by
/// [DatabaseEmbedBuilder].
const String databaseEmbedTag = 'databaseEmbed';

/// Parses whole-line `![[Title]]` and `![[Title#View]]` database embeds.
/// Inline embeds and ordinary wikilinks retain their literal text.
class DatabaseEmbedSyntax extends md.BlockSyntax {
  const DatabaseEmbedSyntax();

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

/// Renders database embed elements using the caller's [embedBuilder].
class DatabaseEmbedBuilder extends MarkdownElementBuilder {
  DatabaseEmbedBuilder({required this.embedBuilder});

  /// Builds the embed for its parsed title and optional view name.
  final Widget Function(BuildContext context, String title, String? view)
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
    return embedBuilder(context, title, view);
  }
}
