import 'package:meta/meta.dart';

/// Matches an inline `#tag` token in a note's markdown body: a `#`
/// immediately followed by one or more ASCII alphanumerics, `-`, `_`, or
/// `/` (the last enabling nesting, e.g. `#work/robot-notes`), per the
/// `notes-storage` "A note's tags merge frontmatter and inline sources"
/// requirement. `#` is not itself an allowed token character, so a run of
/// allowed characters after `#` is always exactly one token — no
/// word-boundary lookaround needed. A markdown heading (`# Heading`, with
/// a space before the text) never matches, since a space isn't allowed.
final RegExp _inlineTagPattern = RegExp(r'#([A-Za-z0-9_\-/]+)');

/// Computes a note's merged, de-duplicated tag set from its frontmatter
/// `tags` array (if present in [extra] as a list of strings) and any
/// inline `#tag` tokens found in [content].
///
/// Matching is case-insensitive for de-duplication (`Urgent` and `urgent`
/// collapse to one entry), but the returned set preserves the casing of
/// the first occurrence — frontmatter entries are considered first, in
/// frontmatter list order, then inline tokens in the order they appear in
/// [content]. This is a deterministic first-seen rule; the spec requires
/// only that *some* stable casing win, not this specific tie-break order.
///
/// This is a pure, read-only computation, never written back into
/// frontmatter: callers recompute it on every write and on startup index
/// rebuild (see `notes-storage` spec), rather than persisting it as its
/// own source of truth.
Set<String> computeTags({
  required Map<String, Object?> extra,
  required String content,
}) {
  final firstSeen = <String, String>{};
  void record(String raw) {
    firstSeen.putIfAbsent(raw.toLowerCase(), () => raw);
  }

  final frontmatterTags = extra['tags'];
  if (frontmatterTags is List) {
    for (final tag in frontmatterTags) {
      if (tag is String && tag.isNotEmpty) record(tag);
    }
  }
  for (final match in _inlineTagPattern.allMatches(content)) {
    record(match.group(1)!);
  }
  return firstSeen.values.toSet();
}

/// One entry of the `GET /tags` response: a tag's first-seen display
/// casing and how many notes currently carry it.
@immutable
class TagCount {
  /// Creates a tag/count pair.
  const TagCount({required this.tag, required this.count});

  /// The tag, in its first-seen display casing (see [aggregateTagCounts]).
  final String tag;

  /// Number of notes currently carrying this tag.
  final int count;
}

/// Aggregates every distinct tag across [tagSets] (one [computeTags]
/// result per note) into a descending-by-count list, per the `notes-api`
/// "GET /tags returns all tags with counts" requirement.
///
/// Case-insensitive matching mirrors [computeTags]: `Urgent` and `urgent`
/// from different notes count as the same tag. The display casing shown
/// is whichever note's set this function encounters first for that tag —
/// a deterministic but otherwise arbitrary tie-break, since the spec only
/// requires *a* stable casing per tag, not a specific note's.
List<TagCount> aggregateTagCounts(Iterable<Set<String>> tagSets) {
  final counts = <String, int>{};
  final display = <String, String>{};
  for (final tags in tagSets) {
    for (final tag in tags) {
      final lower = tag.toLowerCase();
      display.putIfAbsent(lower, () => tag);
      counts.update(lower, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  final result = [
    for (final entry in counts.entries)
      TagCount(tag: display[entry.key]!, count: entry.value),
  ]..sort((a, b) => b.count.compareTo(a.count));
  return result;
}
