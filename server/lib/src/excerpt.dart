/// Matches a fenced or inline code span (fences first, since a fence's
/// `` ` `` run would otherwise be consumed by the inline pattern one
/// backtick at a time).
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

/// Delimiter around a placeholder's index: U+E000 (Private Use Area), a
/// character that never appears in ordinary note content.
const String _placeholder = '\uE000';

/// Matches one of this module's own placeholder tokens (see
/// [_protectCodeSpans]), so a restored code span's *own* punctuation is
/// never mistaken for a second placeholder.
final RegExp _placeholderToken =
    RegExp('$_placeholder' r'(\d+)' '$_placeholder');

/// Replaces every code span (fenced or inline) in [content] with an
/// opaque placeholder, so later markdown-stripping passes (emphasis,
/// headings, tags, …) never touch code contents — `` `snake_case` `` or
/// `` `#pragma once` `` must survive intact, underscores/hashes and all.
/// Returns the placeholder-substituted text alongside the extracted
/// contents, positionally indexed; [_restoreCodeSpans] reverses this. A
/// restored span's own digits can't be mistaken for a second placeholder
/// since restoration happens after every other pass runs.
(String text, List<String> spans) _protectCodeSpans(String content) {
  final spans = <String>[];
  String extract(Match m) {
    spans.add(m.group(1) ?? '');
    return '$_placeholder${spans.length - 1}$_placeholder';
  }

  var text = content.replaceAllMapped(_codeFence, extract);
  text = text.replaceAllMapped(_inlineCode, extract);
  return (text, spans);
}

String _restoreCodeSpans(String text, List<String> spans) {
  return text.replaceAllMapped(
    _placeholderToken,
    (m) => spans[int.parse(m.group(1)!)],
  );
}

/// Computes a bounded, markdown-stripped plain-text preview of a note's
/// [content], for use as a list-row excerpt. Never the note's full content:
/// output is truncated to [maxLength] characters (default 140) on a word
/// boundary, with a trailing `…` when truncation occurred.
///
/// Mirrors `tags.dart`'s `computeTags` in spirit: a pure, read-only
/// computation recomputed by callers on every write and index rebuild,
/// never persisted or cached.
String computeExcerpt(String content, {int maxLength = 140}) {
  final (protectedText, spans) = _protectCodeSpans(content);
  var text = protectedText;
  text = text.replaceAllMapped(
    _wikiLink,
    (m) => m.group(2) ?? m.group(1) ?? '',
  );
  text = text.replaceAll(_headingMarker, '');
  text = text.replaceAll(_listMarker, '');
  text = text.replaceAll(_emphasisMarker, '');
  text = text.replaceAll(_inlineTagToken, '');
  text = _restoreCodeSpans(text, spans);
  text = text.replaceAll(_whitespaceRun, ' ').trim();

  if (text.length <= maxLength) return text;

  final truncated = text.substring(0, maxLength);
  final lastSpace = truncated.lastIndexOf(' ');
  // No word boundary before the limit (a single word longer than
  // maxLength) — hard-truncate rather than return an over-long excerpt.
  final cut = lastSpace > 0 ? truncated.substring(0, lastSpace) : truncated;
  return '${cut.trimRight()}…';
}
