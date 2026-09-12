import 'package:meta/meta.dart';
import 'package:server/src/links.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';

/// A note's outgoing link, stripped of the character-offset position info
/// [ParsedLink] carries (that's only needed transiently for
/// [rewriteLinks]) — just enough to resolve and display it.
@immutable
class LinkEdge {
  /// Creates an edge; consumers do not normally call this directly.
  const LinkEdge({required this.targetTitle, required this.alias});

  /// The linked note's title, exactly as parsed (see [ParsedLink]).
  final String targetTitle;

  /// Optional display text from `[[Title|Alias]]`.
  final String? alias;
}

/// In-memory index of every note's outgoing `[[wikilinks]]`, keyed by
/// source note id.
///
/// This is the companion structure both rename propagation (`note_write_
/// service.dart`) and the backlinks/links endpoints build on:
/// - Outgoing links for a note: [outgoing].
/// - "Which notes link to this title" (used to find rename-propagation
///   candidates, and — joined with [MetaIndex.resolveTitle] by the
///   caller — to answer `GET /notes/{id}/backlinks`): [sourcesLinkingToTitle].
///
/// Like [MetaIndex], this is derived state: rebuilt on startup via [scan]
/// and kept in sync by [upsert]/[remove] calls from the same write path
/// that maintains [MetaIndex]. A personal vault's note count doesn't
/// warrant a persisted or otherwise more elaborate reverse index — a
/// linear scan over [_bySource] is fast enough for [sourcesLinkingToTitle].
///
/// Resolution (title -> id, including phantom-link handling) is
/// intentionally NOT done here: callers resolve a [LinkEdge.targetTitle]
/// against [MetaIndex.resolveTitle] at query time, so a link recorded
/// while its target didn't exist yet starts resolving the moment a
/// matching note appears, without this index needing to know or care.
class LinkIndex {
  final Map<NoteId, List<LinkEdge>> _bySource = {};

  /// Replaces the index contents by parsing every note [metaIndex] knows
  /// about, reading each one's content from [storage]. Used at server
  /// startup, immediately after `metaIndex.scan(storage)`.
  Future<int> scan({
    required MetaIndex metaIndex,
    required Storage storage,
  }) async {
    _bySource.clear();
    for (final summary in metaIndex.all) {
      try {
        final note = await storage.read(summary.id);
        upsert(summary.id, note.content);
      } on NoteNotFoundException {
        // Raced with a concurrent delete between the metaIndex snapshot
        // and this read; the note is gone either way, so just skip it.
      }
    }
    return _bySource.length;
  }

  /// Parses [content] and replaces [id]'s outgoing edges with the result.
  /// Called on every create and update, so the index never drifts from
  /// what's actually on disk.
  void upsert(NoteId id, String content) {
    _bySource[id] = [
      for (final link in parseLinks(content))
        LinkEdge(targetTitle: link.targetTitle, alias: link.alias),
    ];
  }

  /// Drops [id]'s outgoing edges. Idempotent.
  void remove(NoteId id) => _bySource.remove(id);

  /// Returns [id]'s outgoing edges, or an empty list if [id] is unknown
  /// or has none.
  List<LinkEdge> outgoing(NoteId id) =>
      List.unmodifiable(_bySource[id] ?? const []);

  /// Returns the ids of every note with at least one parsed outgoing link
  /// whose target title exactly equals [title]. An incidental plain-text
  /// mention of [title] outside a parsed `[[...]]` span never counts,
  /// since it was never recorded as an edge.
  Iterable<NoteId> sourcesLinkingToTitle(String title) => [
        for (final entry in _bySource.entries)
          if (entry.value.any((e) => e.targetTitle == title)) entry.key,
      ];
}
