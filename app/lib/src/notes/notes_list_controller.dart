import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
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

  bool get hasMore => nextCursor != null;

  NotesListState copyWith({
    List<NoteMeta>? items,
    Object? nextCursor = _sentinel,
    bool? isLoadingFirst,
    bool? isLoadingMore,
    Object? error = _sentinel,
  }) {
    return NotesListState(
      items: items ?? this.items,
      nextCursor: identical(nextCursor, _sentinel)
          ? this.nextCursor
          : nextCursor as String?,
      isLoadingFirst: isLoadingFirst ?? this.isLoadingFirst,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: identical(error, _sentinel) ? this.error : error,
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
  })  : _api = api,
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

  /// Re-fetches the first page. Used both for initial load and pull-to-refresh.
  Future<void> refresh() async {
    if (_disposed) return;
    value = value.copyWith(isLoadingFirst: true, error: null);
    try {
      final page = await _api.listNotes(limit: _pageSize);
      if (_disposed) return;
      value = value.copyWith(
        items: page.items,
        nextCursor: page.nextCursor,
        isLoadingFirst: false,
      );
    } catch (e) {
      if (_disposed) return;
      value = value.copyWith(isLoadingFirst: false, error: e);
    }
  }

  /// Fetches the next page if a cursor is available. No-op if already loading
  /// or exhausted — safe to call from a scroll listener that fires often.
  Future<void> loadMore() async {
    if (_disposed) return;
    if (value.isLoadingMore || !value.hasMore) return;
    value = value.copyWith(isLoadingMore: true, error: null);
    try {
      final page =
          await _api.listNotes(after: value.nextCursor, limit: _pageSize);
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
    switch (msg.action) {
      case ChangeAction.deleted:
        _removeById(msg.noteId);
      case ChangeAction.created:
      case ChangeAction.updated:
        // Content isn't shipped on the WS event — fetch the note so the
        // list shows the current title and version.
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
  }

  void _removeById(String id) {
    final next = value.items.where((n) => n.id != id).toList(growable: false);
    if (next.length == value.items.length) return;
    value = value.copyWith(items: next);
  }

  void _upsert(Note note, {required bool prepend}) {
    final meta = NoteMeta(
      id: note.id,
      title: note.title,
      version: note.version,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
    );
    final idx = value.items.indexWhere((n) => n.id == note.id);
    final List<NoteMeta> next;
    if (idx >= 0) {
      next = <NoteMeta>[...value.items];
      next[idx] = meta;
    } else if (prepend) {
      next = <NoteMeta>[meta, ...value.items];
    } else {
      next = <NoteMeta>[...value.items, meta];
    }
    value = value.copyWith(items: next);
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
