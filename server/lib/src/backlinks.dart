import 'package:meta/meta.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/links.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';

/// One entry of a backlinks listing: the referencing note's id/title and a
/// short excerpt of its content around the link.
@immutable
class BacklinkEntry {
  /// Creates a backlink entry.
  const BacklinkEntry({
    required this.id,
    required this.title,
    required this.snippet,
  });

  /// The referencing note's id.
  final String id;

  /// The referencing note's title.
  final String title;

  /// A short excerpt of the referencing note's content around the link.
  final String snippet;
}

/// Computes every note that links to [targetId], most-recently-updated
/// first — shared by `GET /notes/{id}/backlinks`
/// (`routes/notes/[id]/backlinks.dart`) and the `get_backlinks` MCP tool
/// (`mcp/tools.dart`) so both surfaces stay identical by construction
/// rather than by two hand-kept-in-sync implementations.
///
/// Throws [NoteNotFoundException] when [targetId] is not indexed.
Future<List<BacklinkEntry>> computeBacklinks({
  required NoteId targetId,
  required MetaIndex metaIndex,
  required LinkIndex linkIndex,
  required Storage storage,
}) async {
  final target = metaIndex.get(targetId);
  if (target == null) throw NoteNotFoundException(targetId);

  // A source only counts if its link's target title currently resolves to
  // THIS id — with a duplicate title elsewhere, only the note that wins
  // resolution (MetaIndex.resolveTitle) is ever a valid link target, so
  // only its backlinks should list the source.
  final sourceIds = linkIndex
      .sourcesLinkingToTitle(target.title)
      .where((sourceId) => sourceId != targetId)
      .where((sourceId) => metaIndex.resolveTitle(target.title) == targetId);

  final entries = <MapEntry<NoteSummary, String>>[];
  for (final sourceId in sourceIds) {
    final summary = metaIndex.get(sourceId);
    if (summary == null) continue; // raced with a concurrent delete
    StoredNote source;
    try {
      source = await storage.read(sourceId);
    } on NoteNotFoundException {
      continue;
    }
    final match = parseLinks(source.content).firstWhere(
      (l) => l.targetTitle == target.title,
    );
    entries.add(MapEntry(summary, snippetAround(source.content, match)));
  }
  entries.sort((a, b) => b.key.updatedAt.compareTo(a.key.updatedAt));

  return [
    for (final entry in entries)
      BacklinkEntry(
        id: entry.key.id,
        title: entry.key.title,
        snippet: entry.value,
      ),
  ];
}
