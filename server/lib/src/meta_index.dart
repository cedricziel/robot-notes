import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/storage.dart';

/// Default page size for cursor-based listings. Matches `notes-api`
/// `limit` defaulting; callers can override per-call.
const int kDefaultPageSize = 50;

/// Maximum page size honoured by [MetaIndex.page]. Higher requested
/// limits are clamped silently; the API layer is responsible for
/// telling the client what was applied.
const int kMaxPageSize = 200;

/// Sort order name for the historical, backward-compatible ordering:
/// ascending by id. This is the default when `sort` is omitted.
const String kSortId = 'id';

/// Sort order name for newest-updated-first ordering: `updated_at`
/// descending, ties broken by `id` descending.
const String kSortUpdatedDesc = 'updated_desc';

/// The complete set of `sort` values [MetaIndex.page] accepts. Callers
/// (e.g. the `GET /notes` route) SHOULD validate against this before
/// calling [MetaIndex.page] so they can return a 400 with a clear
/// message rather than relying on [MetaIndex.page]'s [ArgumentError].
const Set<String> kSupportedSorts = {kSortId, kSortUpdatedDesc};

/// Shared wording for a rejected `sort` value, used by every transport
/// that exposes [MetaIndex.page] (the `GET /notes` route and the MCP
/// `list_notes` tool) so the message stays identical across both.
const String kSortErrorMessage = 'sort must be one of: id, updated_desc';

/// Thrown by [MetaIndex.page] when an `after` cursor cannot be decoded
/// for the requested `sort`. Only relevant to [kSortUpdatedDesc], whose
/// cursor packs `updated_at` and `id` together; [kSortId] cursors are a
/// plain id and can't be malformed in this sense.
class InvalidCursorException implements Exception {
  /// Creates an exception for the given raw cursor value.
  InvalidCursorException(this.cursor);

  /// The cursor value that failed to decode.
  final String cursor;

  @override
  String toString() => 'InvalidCursorException: $cursor';
}

/// Result of a paginated [MetaIndex.page] call.
@immutable
class MetaIndexPage {
  /// Creates a page result.
  const MetaIndexPage({required this.items, required this.nextCursor});

  /// Note summaries in this page, ordered per the `sort` the page was
  /// requested with.
  final List<NoteSummary> items;

  /// Cursor to pass as `after` on the next call. `null` when this page
  /// reached the end of the index.
  final String? nextCursor;
}

/// In-memory authoritative listing of notes during the server's
/// lifetime. Backed by an id → [NoteSummary] map plus a sorted key list
/// for O(log n) cursor pagination.
///
/// The index is **derived state**: it is populated on startup by
/// [scan]ing the canonical storage layer and kept in sync via
/// [upsert] / [remove] calls from the notes-API handlers. Out-of-band
/// filesystem edits during runtime are intentionally not picked up
/// (per `notes-storage` v1).
class MetaIndex {
  /// Creates an empty index.
  MetaIndex({Logger? logger}) : _log = logger ?? Logger('meta_index');

  final Logger _log;
  final Map<NoteId, NoteSummary> _byId = {};
  // Sorted ascending. Maintained alongside _byId; binary-searched for
  // cursor pagination so we never re-sort on every page request.
  final List<NoteId> _sortedIds = [];
  // Sorted by (updatedAt desc, id desc). Unlike _sortedIds, an existing
  // entry's position here moves whenever its updatedAt changes, so
  // upsert must reposition rather than only insert-if-new.
  final List<NoteId> _sortedByUpdated = [];
  // title -> ids of every note currently carrying that exact title,
  // ascending. Almost always a single-element list; a personal vault's
  // note count doesn't warrant more than a plain list for the rare
  // duplicate-title case (see resolveTitle).
  final Map<String, List<NoteId>> _byTitle = {};

  // Folder paths known to hold an empty-folder marker (see
  // `storage.dart`'s `kFolderMarkerFilename`), i.e. folders with no notes
  // that still need to appear in `GET /notes/tree`. Repopulated wholesale
  // by [scan] from [Storage.emptyFolderPaths]; individual entries are
  // added by [registerEmptyFolder] when a folder is created without a
  // full rescan.
  final Set<String> _emptyFolders = {};

  /// Number of entries currently held.
  int get length => _byId.length;

  /// Snapshot of every currently-indexed summary, in no particular order.
  /// Used by `path`/`tag` filtering (see [page]) and by `GET /notes/tree`.
  Iterable<NoteSummary> get all => _byId.values;

  /// Folder paths known to hold an empty-folder marker, i.e. folders that
  /// should be listed by `GET /notes/tree` even though they have no
  /// notes. A path may also have notes; the two are not mutually
  /// exclusive.
  Set<String> get emptyFolders => Set.unmodifiable(_emptyFolders);

  /// Replaces the index contents with everything [storage] reports as
  /// well-formed. Files that fail to parse are skipped and logged by
  /// [Storage.list]; this method itself never throws on malformed input.
  Future<int> scan(Storage storage) async {
    _byId.clear();
    _sortedIds.clear();
    _sortedByUpdated.clear();
    _byTitle.clear();
    final summaries = await storage.list();
    for (final s in summaries) {
      _byId[s.id] = s;
      _sortedIds.add(s.id);
      _sortedByUpdated.add(s.id);
      _indexTitle(s);
    }
    _sortedIds.sort();
    _sortedByUpdated.sort(
      (a, b) => _compareUpdatedDesc(_byId[a]!, _byId[b]!),
    );
    _emptyFolders
      ..clear()
      ..addAll(storage.emptyFolderPaths);
    _log.info('Indexed ${_byId.length} note(s)');
    return _byId.length;
  }

  /// Registers [path] as a known-empty folder without a full [scan],
  /// e.g. right after `POST /notes/tree` creates it on disk.
  void registerEmptyFolder(String path) => _emptyFolders.add(path);

  /// Returns the summary for [id], or `null` if no such id is indexed.
  NoteSummary? get(NoteId id) => _byId[id];

  /// Inserts or replaces the summary for `summary.id`. Both sorted key
  /// lists are kept consistent; an existing entry's position in the
  /// updated-at ordering is recomputed since its `updatedAt` may have
  /// changed.
  void upsert(NoteSummary summary) {
    final existing = _byId[summary.id];
    if (existing != null) _removeSortedByUpdated(existing);
    if (existing != null && existing.title != summary.title) {
      _deindexTitle(existing);
    }
    _byId[summary.id] = summary;
    if (existing == null) _insertSorted(summary.id);
    if (existing == null || existing.title != summary.title) {
      _indexTitle(summary);
    }
    _insertSortedByUpdated(summary);
  }

  /// Removes the entry for [id] if present. Idempotent.
  void remove(NoteId id) {
    final existing = _byId[id];
    if (existing == null) return;
    // Locate the entry in _sortedByUpdated before dropping it from
    // _byId: the search compares against _byId values, including
    // this entry's own (still needed to find itself).
    _removeSortedByUpdated(existing);
    _deindexTitle(existing);
    _byId.remove(id);
    final pos = _binarySearch(_sortedIds, id);
    if (pos >= 0) _sortedIds.removeAt(pos);
  }

  /// Resolves [title] to the id of the note it currently identifies, or
  /// `null` if no indexed note carries that exact title (a "phantom"
  /// link target). Resolution happens at call time against live index
  /// state, so a link recorded while its target title didn't exist yet
  /// starts resolving the moment a matching note is indexed — no
  /// re-save of the linking note required.
  ///
  /// When more than one note shares [title], resolution is deterministic
  /// (the ascending-sorted-first id always wins) and an ambiguous-title
  /// warning naming every id sharing the title is logged, per
  /// `links` spec.
  NoteId? resolveTitle(String title) {
    final ids = _byTitle[title];
    if (ids == null || ids.isEmpty) return null;
    if (ids.length > 1) {
      _log.warning(
        'Ambiguous title "$title": ids ${ids.join(', ')} all match; '
        'resolving to ${ids.first}',
      );
    }
    return ids.first;
  }

  void _indexTitle(NoteSummary summary) {
    final ids = _byTitle.putIfAbsent(summary.title, () => []);
    if (ids.contains(summary.id)) return;
    ids
      ..add(summary.id)
      ..sort();
  }

  void _deindexTitle(NoteSummary summary) {
    final ids = _byTitle[summary.title];
    if (ids == null) return;
    ids.remove(summary.id);
    if (ids.isEmpty) _byTitle.remove(summary.title);
  }

  /// Returns a page of summaries ordered per [sort], up to [limit]
  /// entries. [limit] is clamped to [kMaxPageSize].
  ///
  /// [sort] SHALL be one of [kSupportedSorts]; callers are expected to
  /// validate the raw query value themselves so they can respond with a
  /// tailored 400 rather than relying on the [ArgumentError] this throws
  /// for an unrecognised value.
  ///
  /// For [kSortId] (the default), [after] is the last-seen id and the
  /// returned cursor is a plain id, unchanged from before [sort] existed.
  /// For [kSortUpdatedDesc], [after] SHALL be a cursor previously
  /// returned by this method for the same sort; passing anything else
  /// throws [InvalidCursorException].
  ///
  /// [pathPrefix], when non-null, narrows the result to notes whose
  /// `path` equals [pathPrefix] or is nested under it (`path ==
  /// pathPrefix || path.startsWith('$pathPrefix/')`), applied *before*
  /// pagination — a personal vault's note count doesn't warrant a
  /// second sorted index per folder, so this is a linear pre-filter over
  /// the same sorted candidate list [sort] would otherwise page over
  /// directly.
  ///
  /// [tag], when non-null, narrows the result the same way to notes
  /// whose computed [NoteSummary.tags] contains [tag] (case-insensitive,
  /// matching `tags.dart`'s `computeTags` matching rule) — the identical
  /// pre-filter mechanism as [pathPrefix], composable with it and with
  /// either [sort].
  MetaIndexPage page({
    String? after,
    int limit = kDefaultPageSize,
    String sort = kSortId,
    String? pathPrefix,
    String? tag,
  }) {
    final effectiveLimit = limit.clamp(1, kMaxPageSize);
    switch (sort) {
      case kSortId:
        return _pageById(
          after: after,
          limit: effectiveLimit,
          pathPrefix: pathPrefix,
          tag: tag,
        );
      case kSortUpdatedDesc:
        return _pageByUpdated(
          after: after,
          limit: effectiveLimit,
          pathPrefix: pathPrefix,
          tag: tag,
        );
      default:
        throw ArgumentError.value(sort, 'sort', 'unsupported sort');
    }
  }

  bool _matchesPathPrefix(NoteSummary summary, String? pathPrefix) {
    if (pathPrefix == null) return true;
    return summary.path == pathPrefix ||
        summary.path.startsWith('$pathPrefix/');
  }

  bool _matchesTag(NoteSummary summary, String? tag) {
    if (tag == null) return true;
    final lower = tag.toLowerCase();
    return summary.tags.any((t) => t.toLowerCase() == lower);
  }

  bool _matchesFilters(NoteSummary summary, String? pathPrefix, String? tag) {
    return _matchesPathPrefix(summary, pathPrefix) && _matchesTag(summary, tag);
  }

  MetaIndexPage _pageById({
    required String? after,
    required int limit,
    String? pathPrefix,
    String? tag,
  }) {
    final candidates = pathPrefix == null && tag == null
        ? _sortedIds
        : [
            for (final id in _sortedIds)
              if (_matchesFilters(_byId[id]!, pathPrefix, tag)) id,
          ];
    int startIdx;
    if (after == null) {
      startIdx = 0;
    } else {
      final pos = _binarySearch(candidates, after);
      // If `after` is not in the candidate list, find its insertion
      // point — the next id in sort order. If it is, start at the entry
      // after it.
      startIdx = pos >= 0 ? pos + 1 : -(pos + 1);
    }
    final endIdx = (startIdx + limit).clamp(0, candidates.length);
    final pageIds = candidates.sublist(startIdx, endIdx);
    final items = [for (final id in pageIds) _byId[id]!];
    final nextCursor = endIdx < candidates.length ? pageIds.last : null;
    return MetaIndexPage(items: items, nextCursor: nextCursor);
  }

  MetaIndexPage _pageByUpdated({
    required String? after,
    required int limit,
    String? pathPrefix,
    String? tag,
  }) {
    final candidates = pathPrefix == null && tag == null
        ? _sortedByUpdated
        : [
            for (final id in _sortedByUpdated)
              if (_matchesFilters(_byId[id]!, pathPrefix, tag)) id,
          ];
    int startIdx;
    if (after == null) {
      startIdx = 0;
    } else {
      final cursor = _decodeUpdatedCursor(after);
      final pos = _binarySearchByUpdated(
        cursor.updatedAt,
        cursor.id,
        candidates,
      );
      startIdx = pos >= 0 ? pos + 1 : -(pos + 1);
    }
    final endIdx = (startIdx + limit).clamp(0, candidates.length);
    final pageIds = candidates.sublist(startIdx, endIdx);
    final items = [for (final id in pageIds) _byId[id]!];
    final nextCursor =
        endIdx < candidates.length ? _encodeUpdatedCursor(items.last) : null;
    return MetaIndexPage(items: items, nextCursor: nextCursor);
  }

  void _insertSorted(NoteId id) {
    final pos = _binarySearch(_sortedIds, id);
    final insertAt = pos >= 0 ? pos : -(pos + 1);
    _sortedIds.insert(insertAt, id);
  }

  void _insertSortedByUpdated(NoteSummary summary) {
    final pos = _binarySearchByUpdated(summary.updatedAt, summary.id);
    final insertAt = pos >= 0 ? pos : -(pos + 1);
    _sortedByUpdated.insert(insertAt, summary.id);
  }

  void _removeSortedByUpdated(NoteSummary summary) {
    final pos = _binarySearchByUpdated(summary.updatedAt, summary.id);
    if (pos >= 0) _sortedByUpdated.removeAt(pos);
  }

  // Locates (updatedAt, id) in [candidates] (defaulting to the full
  // _sortedByUpdated field) by delegating to the same index-based search
  // _binarySearch uses for _sortedIds. Callers that already narrowed the
  // candidate list to a path-filtered subset (see _pageByUpdated) pass it
  // explicitly so the search matches what's actually being paged over.
  int _binarySearchByUpdated(
    DateTime updatedAt,
    NoteId id, [
    List<NoteId>? candidates,
  ]) {
    final list = candidates ?? _sortedByUpdated;
    return _binarySearchIndexed(list.length, (mid) {
      final midSummary = _byId[list[mid]]!;
      return _compareUpdatedKey(
        midSummary.updatedAt,
        midSummary.id,
        updatedAt,
        id,
      );
    });
  }

  static int _compareUpdatedDesc(NoteSummary a, NoteSummary b) =>
      _compareUpdatedKey(a.updatedAt, a.id, b.updatedAt, b.id);

  static int _compareUpdatedKey(
    DateTime aUpdatedAt,
    NoteId aId,
    DateTime bUpdatedAt,
    NoteId bId,
  ) {
    final cmp = bUpdatedAt.compareTo(aUpdatedAt);
    if (cmp != 0) return cmp;
    return bId.compareTo(aId);
  }

  static String _encodeUpdatedCursor(NoteSummary summary) {
    final raw = '${summary.updatedAt.toUtc().toIso8601String()}'
        '|${summary.id}';
    return base64Url.encode(utf8.encode(raw));
  }

  static ({DateTime updatedAt, NoteId id}) _decodeUpdatedCursor(
    String cursor,
  ) {
    try {
      final raw = utf8.decode(base64Url.decode(cursor));
      final sep = raw.indexOf('|');
      if (sep < 0) throw InvalidCursorException(cursor);
      final updatedAt = DateTime.parse(raw.substring(0, sep)).toUtc();
      final id = raw.substring(sep + 1);
      if (id.isEmpty) throw InvalidCursorException(cursor);
      return (updatedAt: updatedAt, id: id);
    } on Object catch (_) {
      throw InvalidCursorException(cursor);
    }
  }

  // Returns the index of [target], or `-(insertionPoint + 1)` if absent.
  // Mirrors `Collections.binarySearch`'s contract.
  int _binarySearch(List<String> list, String target) {
    return _binarySearchIndexed(
      list.length,
      (mid) => list[mid].compareTo(target),
    );
  }

  // Generic index-based binary search shared by [_binarySearch] and
  // [_binarySearchByUpdated]: [compare] compares the element at an index
  // against the (implicit) search target, using the same sign convention
  // as [Comparable.compareTo]. Returns the index of an exact match, or
  // `-(insertionPoint + 1)` if absent.
  static int _binarySearchIndexed(int length, int Function(int index) compare) {
    var lo = 0;
    var hi = length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >>> 1;
      final cmp = compare(mid);
      if (cmp == 0) return mid;
      if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -(lo + 1);
  }
}
