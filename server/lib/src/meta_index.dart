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

/// Result of a paginated [MetaIndex.page] call.
@immutable
class MetaIndexPage {
  /// Creates a page result.
  const MetaIndexPage({required this.items, required this.nextCursor});

  /// Note summaries in this page, in id-ascending order.
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

  /// Number of entries currently held.
  int get length => _byId.length;

  /// Replaces the index contents with everything [storage] reports as
  /// well-formed. Files that fail to parse are skipped and logged by
  /// [Storage.list]; this method itself never throws on malformed input.
  Future<int> scan(Storage storage) async {
    _byId.clear();
    _sortedIds.clear();
    final summaries = await storage.list();
    for (final s in summaries) {
      _byId[s.id] = s;
      _sortedIds.add(s.id);
    }
    _sortedIds.sort();
    _log.info('Indexed ${_byId.length} note(s)');
    return _byId.length;
  }

  /// Returns the summary for [id], or `null` if no such id is indexed.
  NoteSummary? get(NoteId id) => _byId[id];

  /// Inserts or replaces the summary for `summary.id`. The sorted key
  /// list is kept consistent.
  void upsert(NoteSummary summary) {
    final isNew = !_byId.containsKey(summary.id);
    _byId[summary.id] = summary;
    if (isNew) {
      _insertSorted(summary.id);
    }
  }

  /// Removes the entry for [id] if present. Idempotent.
  void remove(NoteId id) {
    if (_byId.remove(id) == null) return;
    final pos = _binarySearch(_sortedIds, id);
    if (pos >= 0) _sortedIds.removeAt(pos);
  }

  /// Returns a page of summaries with ids strictly greater than [after],
  /// up to [limit] entries. [limit] is clamped to [kMaxPageSize].
  MetaIndexPage page({String? after, int limit = kDefaultPageSize}) {
    final effectiveLimit = limit.clamp(1, kMaxPageSize);
    int startIdx;
    if (after == null) {
      startIdx = 0;
    } else {
      final pos = _binarySearch(_sortedIds, after);
      // If `after` is not in the index, find its insertion point — the
      // next id in sort order. If it is, start at the entry after it.
      startIdx = pos >= 0 ? pos + 1 : -(pos + 1);
    }
    final endIdx = (startIdx + effectiveLimit).clamp(0, _sortedIds.length);
    final pageIds = _sortedIds.sublist(startIdx, endIdx);
    final items = [for (final id in pageIds) _byId[id]!];
    final nextCursor = endIdx < _sortedIds.length ? pageIds.last : null;
    return MetaIndexPage(items: items, nextCursor: nextCursor);
  }

  void _insertSorted(NoteId id) {
    final pos = _binarySearch(_sortedIds, id);
    final insertAt = pos >= 0 ? pos : -(pos + 1);
    _sortedIds.insert(insertAt, id);
  }

  // Returns the index of [target], or `-(insertionPoint + 1)` if absent.
  // Mirrors `Collections.binarySearch`'s contract.
  int _binarySearch(List<String> list, String target) {
    var lo = 0;
    var hi = list.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >>> 1;
      final cmp = list[mid].compareTo(target);
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
