import 'package:meta/meta.dart';

/// Matches an inline `[[Title]]` or `[[Title|Alias]]` occurrence. Non-greedy
/// so `[[First]] ... [[Second]]` yields two matches instead of one spanning
/// both — the first `]]` always closes the nearest `[[`.
///
/// `.` does not match a newline by default, which is intentional: a link
/// target is expected to sit on a single line, matching Obsidian's own
/// behaviour.
final RegExp _linkPattern = RegExp(r'\[\[(.+?)\]\]');

/// A single `[[Title]]` / `[[Title|Alias]]` occurrence found in a note's
/// markdown content by [parseLinks].
///
/// [start] and [end] are byte-for-byte offsets into the source string
/// (`content.substring(start, end)` reproduces the exact matched text,
/// brackets included), which is what lets [rewriteLinks] replace a link's
/// span without disturbing anything around it.
@immutable
class ParsedLink {
  /// Creates a parsed link. Not normally constructed directly outside
  /// [parseLinks].
  const ParsedLink({
    required this.targetTitle,
    required this.alias,
    required this.start,
    required this.end,
  });

  /// The linked note's title, exactly as written between the brackets (and
  /// before any `|alias` split). `[[Title#Heading]]` is NOT given
  /// heading-anchor treatment in this version: the full bracketed text
  /// (`Title#Heading`) is the target title.
  final String targetTitle;

  /// Optional display text from `[[Title|Alias]]`; `null` for a bare
  /// `[[Title]]` link.
  final String? alias;

  /// Index of the opening `[` in the source content.
  final int start;

  /// Index just past the closing `]]` in the source content (exclusive).
  final int end;
}

/// Extracts every `[[Title]]` / `[[Title|Alias]]` occurrence from [content]
/// in document order. Parsing is read-only: [content] is never modified,
/// and the raw `[[...]]` text is preserved verbatim in the source file by
/// every caller of this function.
///
/// A title containing a literal `|` or `]]` cannot be linked unambiguously
/// (per `links` spec) — such a link parses as whatever text precedes the
/// first `|` or `]]`, which is a documented limitation rather than a bug.
List<ParsedLink> parseLinks(String content) {
  final links = <ParsedLink>[];
  for (final match in _linkPattern.allMatches(content)) {
    final inner = match.group(1)!;
    final pipeIndex = inner.indexOf('|');
    final targetTitle = pipeIndex < 0 ? inner : inner.substring(0, pipeIndex);
    final alias = pipeIndex < 0 ? null : inner.substring(pipeIndex + 1);
    links.add(
      ParsedLink(
        targetTitle: targetTitle,
        alias: alias,
        start: match.start,
        end: match.end,
      ),
    );
  }
  return links;
}

/// Rewrites every parsed link in [content] whose target title exactly
/// equals [oldTitle] so it instead targets [newTitle], preserving any
/// alias text unchanged. Only text inside a parsed `[[...]]` span is
/// touched — an incidental plain-text mention of [oldTitle] elsewhere in
/// [content] is left alone, since it was never a parsed link.
///
/// Returns [content] unchanged (same instance) when there is nothing to
/// rewrite.
String rewriteLinks(
  String content, {
  required String oldTitle,
  required String newTitle,
}) {
  final matching = [
    for (final link in parseLinks(content))
      if (link.targetTitle == oldTitle) link,
  ];
  if (matching.isEmpty) return content;

  final buffer = StringBuffer();
  var cursor = 0;
  for (final link in matching) {
    buffer
      ..write(content.substring(cursor, link.start))
      ..write(
        link.alias == null ? '[[$newTitle]]' : '[[$newTitle|${link.alias}]]',
      );
    cursor = link.end;
  }
  buffer.write(content.substring(cursor));
  return buffer.toString();
}

/// Builds a short excerpt of [content] centered on [link], for display in a
/// backlinks list. Includes up to [radius] characters of surrounding
/// context on each side, with an ellipsis marking truncation.
String snippetAround(String content, ParsedLink link, {int radius = 40}) {
  final start = (link.start - radius).clamp(0, content.length);
  final end = (link.end + radius).clamp(0, content.length);
  final excerpt = content.substring(start, end);
  final prefix = start > 0 ? '…' : '';
  final suffix = end < content.length ? '…' : '';
  return '$prefix$excerpt$suffix';
}
