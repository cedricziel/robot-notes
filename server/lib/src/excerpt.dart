/// Matches a fenced or inline code span so its markers can be dropped
/// while keeping the code text itself (fences first, since a fence's `` ` ``
/// run would otherwise be consumed by the inline pattern one backtick at a
/// time).
final RegExp _codeFence = RegExp(r'```([\s\S]*?)```');
final RegExp _inlineCode = RegExp('`([^`]*)`');

/// Matches a wiki-style link: `[[Title|Alias]]` or `[[Title]]`.
final RegExp _wikiLink = RegExp(r'\[\[([^\]|]+)(?:\|([^\]]+))?\]\]');

/// Matches a leading heading marker (`#`, `##`, … up to 6) at line start.
final RegExp _headingMarker = RegExp('^#{1,6} +', multiLine: true);

/// Matches a leading list marker (`-`, `*`, `+`, or `1.`) at line start.
final RegExp _listMarker = RegExp(r'^(?:[-*+]|\d+\.) +', multiLine: true);

/// Matches emphasis markers (`**`, `*`, `_`), stripped without requiring a
/// matching close so an unbalanced marker doesn't leave the rest of the
/// excerpt untouched.
final RegExp _emphasisMarker = RegExp(r'\*\*|\*|_');

/// Matches an inline `#tag` token — identical shape to `tags.dart`'s
/// `_inlineTagPattern`, but kept local since this module serves a
/// different purpose (a display excerpt, not tag extraction) and the two
/// call sites have no other reason to share a dependency.
final RegExp _inlineTagToken = RegExp(r'#[A-Za-z0-9_\-/]+');

/// Matches any run of whitespace (including newlines).
final RegExp _whitespaceRun = RegExp(r'\s+');

/// Computes a bounded, markdown-stripped plain-text preview of a note's
/// [content], for use as a list-row excerpt. Never the note's full content:
/// output is truncated to [maxLength] characters (default 140) on a word
/// boundary, with a trailing `…` when truncation occurred.
///
/// Mirrors `tags.dart`'s `computeTags` in spirit: a pure, read-only
/// computation recomputed by callers on every write and index rebuild,
/// never persisted or cached.
String computeExcerpt(String content, {int maxLength = 140}) {
  var text = content;
  text = text.replaceAllMapped(_codeFence, (m) => m.group(1) ?? '');
  text = text.replaceAllMapped(_inlineCode, (m) => m.group(1) ?? '');
  text = text.replaceAllMapped(
    _wikiLink,
    (m) => m.group(2) ?? m.group(1) ?? '',
  );
  text = text.replaceAll(_headingMarker, '');
  text = text.replaceAll(_listMarker, '');
  text = text.replaceAll(_emphasisMarker, '');
  text = text.replaceAll(_inlineTagToken, '');
  text = text.replaceAll(_whitespaceRun, ' ').trim();

  if (text.length <= maxLength) return text;

  final truncated = text.substring(0, maxLength);
  final lastSpace = truncated.lastIndexOf(' ');
  // No word boundary before the limit (a single word longer than
  // maxLength) — hard-truncate rather than return an over-long excerpt.
  final cut = lastSpace > 0 ? truncated.substring(0, lastSpace) : truncated;
  return '${cut.trimRight()}…';
}
