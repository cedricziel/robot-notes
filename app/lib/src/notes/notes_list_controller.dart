import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../realtime/ws_client.dart';

/// Snapshot of the list view's state. Renders directly via [ValueListenable].
@immutable
class NotesListState {
  const NotesListState({
    this.items = const <NoteMeta>[],
    this.nextCursor,
    this.isLoadingFirst = false,
    this.isLoadingMore = false,
    this.error,
    this.selectedPath,
    this.selectedTag,
  });

  /// Initial state used before the first refresh kicks in.
  static const empty = NotesListState();

  final List<NoteMeta> items;

  /// Cursor for the next page, or `null` once the server says we're done.
  final String? nextCursor;
  final bool isLoadingFirst;
  final bool isLoadingMore;

  /// The last error from a refresh/loadMore. Cleared on the next successful
  /// fetch. UI surfaces this as a non-blocking banner.
  final Object? error;

  /// Folder the list is currently scoped to (via the sidebar), or `null` for
  /// "All notes". Applied as the `path` query parameter on every request.
  final String? selectedPath;

  /// Tag the list is currently scoped to (via a tag chip), or `null` for no
  /// tag filter. Applied as the `tag` query parameter on every request.
  final String? selectedTag;

  bool get hasMore => nextCursor != null;

  NotesListState copyWith({
    List<NoteMeta>? items,
    Object? nextCursor = _sentinel,
    bool? isLoadingFirst,
    bool? isLoadingMore,
    Object? error = _sentinel,
    Object? selectedPath = _sentinel,
    Object? selectedTag = _sentinel,
  }) {
    return NotesListState(
      items: items ?? this.items,
      nextCursor: identical(nextCursor, _sentinel)
          ? this.nextCursor
          : nextCursor as String?,
      isLoadingFirst: isLoadingFirst ?? this.isLoadingFirst,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: identical(error, _sentinel) ? this.error : error,
      selectedPath: identical(selectedPath, _sentinel)
          ? this.selectedPath
          : selectedPath as String?,
      selectedTag: identical(selectedTag, _sentinel)
          ? this.selectedTag
          : selectedTag as String?,
    );
  }
}

const Object _sentinel = Object();

/// Drives the notes list view. Pulls pages over HTTP and folds in live
/// `changed` events from the realtime stream so the list stays in sync
/// without manual refreshes.
///
/// All side effects route through [api] and the optional [events] stream so
/// widget tests can drive both deterministically.
class NotesListController extends ValueNotifier<NotesListState> {
  NotesListController({
    required RobotNotesClient api,
    Stream<RealtimeEvent>? events,
    int pageSize = 50,
  }) : _api = api,
       _pageSize = pageSize,
       super(NotesListState.empty) {
    if (events != null) {
      _sub = events.listen(_onEvent);
    }
  }

  final RobotNotesClient _api;
  final int _pageSize;
  StreamSubscription<RealtimeEvent>? _sub;
  bool _disposed = false;
  Future<void>? _refreshInFlight;

  /// Re-fetches the first page. Used both for initial load and pull-to-refresh.
  ///
  /// A refresh already in flight (e.g. a stale-reconnect refetch landing
  /// during a pull-to-refresh) is coalesced into the same request rather than
  /// issuing a second one, so the two results can't race to overwrite each
  /// other.
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    return _refreshInFlight ??= _doRefresh();
  }

  Future<void> _doRefresh() async {
    value = value.copyWith(isLoadingFirst: true, error: null);
    try {
      final page = await _api.listNotes(
        limit: _pageSize,
        sort: 'updated_desc',
        path: value.selectedPath,
        tag: value.selectedTag,
      );
      if (_disposed) return;
      value = value.copyWith(
        items: page.items,
        nextCursor: page.nextCursor,
        isLoadingFirst: false,
      );
    } catch (e) {
      if (_disposed) return;
      value = value.copyWith(isLoadingFirst: false, error: e);
    } finally {
      _refreshInFlight = null;
    }
  }

  /// Scopes the list to [path] (or clears the scope for `null`, i.e. "All
  /// notes") and re-fetches immediately.
  Future<void> selectFolder(String? path) {
    if (_disposed) return Future<void>.value();
    value = value.copyWith(selectedPath: path);
    return refresh();
  }

  /// Scopes the list to notes carrying [tag] (or clears the scope for
  /// `null`) and re-fetches immediately.
  Future<void> selectTag(String? tag) {
    if (_disposed) return Future<void>.value();
    value = value.copyWith(selectedTag: tag);
    return refresh();
  }

  /// Fetches the next page if a cursor is available. No-op if already loading
  /// or exhausted — safe to call from a scroll listener that fires often.
  Future<void> loadMore() async {
    if (_disposed) return;
    if (value.isLoadingMore || !value.hasMore) return;
    value = value.copyWith(isLoadingMore: true, error: null);
    try {
      final page = await _api.listNotes(
        after: value.nextCursor,
        limit: _pageSize,
        sort: 'updated_desc',
        path: value.selectedPath,
        tag: value.selectedTag,
      );
      if (_disposed) return;
      value = value.copyWith(
        items: <NoteMeta>[...value.items, ...page.items],
        nextCursor: page.nextCursor,
        isLoadingMore: false,
      );
    } catch (e) {
      if (_disposed) return;
      value = value.copyWith(isLoadingMore: false, error: e);
    }
  }

  Future<void> _onEvent(RealtimeEvent event) async {
    if (event is! RealtimeMessage) return;
    final msg = event.message;
    if (msg is! ChangedEvent) return;
    if (msg.action == ChangeAction.deleted) {
      _removeById(msg.noteId);
      return;
    }
    if (msg.action == ChangeAction.moved && value.selectedPath != null) {
      // A moved note may have left (or entered) the active folder scope,
      // and the WS event doesn't carry the new path to check locally — a
      // full re-fetch is the only way to know whether it still belongs.
      unawaited(refresh());
      return;
    }
    // created / updated / moved (unscoped): content isn't shipped on the WS
    // event — fetch the note so the list shows the current title and
    // version.
    try {
      final note = await _api.getNote(msg.noteId);
      if (_disposed) return;
      _upsert(note, prepend: msg.action == ChangeAction.created);
    } catch (_) {
      // Best-effort live update; on failure the next refresh will
      // reconcile. Don't surface as a list-level error since the user
      // didn't initiate this fetch.
    }
  }

  void _removeById(String id) {
    final next = value.items.where((n) => n.id != id).toList(growable: false);
    if (next.length == value.items.length) return;
    value = value.copyWith(items: next);
  }

  void _upsert(Note note, {required bool prepend}) {
    final idx = value.items.indexWhere((n) => n.id == note.id);
    // GET /notes/{id} (what a `changed` event triggers) never carries an
    // excerpt — only the list endpoint computes one. Keep the previous
    // entry's excerpt rather than blanking it; it goes stale until the
    // next full refresh, which beats the row losing its preview text on
    // every live edit.
    final previousExcerpt = idx >= 0 ? value.items[idx].excerpt : '';
    final meta = NoteMeta(
      id: note.id,
      title: note.title,
      path: note.path,
      version: note.version,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      excerpt: previousExcerpt,
      tags: note.tags,
    );
    final rest = idx >= 0
        ? <NoteMeta>[...value.items.take(idx), ...value.items.skip(idx + 1)]
        : value.items;
    // The list is newest-updated-first, so an already-listed note that
    // just changed is now the most recent and belongs at the top, not in
    // its old slot — the same place a brand-new ("prepend") note goes.
    final next = (idx >= 0 || prepend)
        ? <NoteMeta>[meta, ...rest]
        : <NoteMeta>[...rest, meta];
    value = value.copyWith(items: next);
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }

  /// Sends `DELETE /notes/{id}` and removes the item from the list on
  /// success, returning `true`. A 404 counts as success: the note is gone
  /// either way. Any other error leaves the item in place, surfaces via
  /// [NotesListState.error], and returns `false`.
  Future<bool> delete(String id) async {
    if (_disposed) return false;
    try {
      await _api.deleteNote(id);
    } on NotFoundException {
      // Already gone; fall through to removing it locally.
    } on ApiException catch (e) {
      if (_disposed) return false;
      value = value.copyWith(error: e);
      return false;
    }
    if (_disposed) return false;
    _removeById(id);
    return true;
  }
}
