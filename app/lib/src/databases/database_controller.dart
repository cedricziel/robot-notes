import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../realtime/ws_client.dart';
import '../widgets/error_strip.dart';
import 'databases_controller.dart';

/// High-level state of an open database screen.
enum DatabaseScreenMode {
  /// The definition (and, once resolved, the first page of rows) is
  /// loading.
  loading,

  /// The definition loaded and rows are available (possibly empty).
  ready,

  /// `GET /databases/{id}` returned 404.
  notFound,

  /// The definition, or the row query, failed for another reason.
  error,
}

/// One column of a board view: an option of the `group_by` property (or the
/// trailing "No value" column), its own page of rows, and its own cursor —
/// paged independently, per design.md.
@immutable
class BoardColumn {
  const BoardColumn({
    required this.label,
    required this.value,
    this.isNoValue = false,
    this.items = const <DatabaseRow>[],
    this.count = 0,
    this.nextCursor,
    this.isLoadingMore = false,
  });

  /// The column header, e.g. the option string, or "No value".
  final String label;

  /// The option value this column filters on. `null` for the "No value"
  /// column (which filters with `is_empty` rather than `eq`).
  final Object? value;
  final bool isNoValue;

  final List<DatabaseRow> items;

  /// The server's count for this column, from `groups` — independent of
  /// how many [items] have been paged in so far.
  final int count;
  final String? nextCursor;
  final bool isLoadingMore;

  bool get hasMore => nextCursor != null;

  BoardColumn copyWith({
    List<DatabaseRow>? items,
    int? count,
    Object? nextCursor = _sentinel,
    bool? isLoadingMore,
  }) {
    return BoardColumn(
      label: label,
      value: value,
      isNoValue: isNoValue,
      items: items ?? this.items,
      count: count ?? this.count,
      nextCursor: identical(nextCursor, _sentinel)
          ? this.nextCursor
          : nextCursor as String?,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }
}

/// Recorded when an edit (a cell patch or a board drag) makes a row no
/// longer match the current view's filter. The row is kept on screen until
/// the next re-query removes it, at which point this notice offers undo by
/// re-applying [previousSet] / [previousUnset].
@immutable
class LeftViewNotice {
  const LeftViewNotice({
    required this.noteId,
    required this.title,
    required this.previousSet,
    required this.previousUnset,
  });

  final String noteId;
  final String title;

  /// The property value(s) to restore on undo.
  final Map<String, Object?> previousSet;
  final List<String> previousUnset;
}

/// Snapshot of [DatabaseController] state. Drives the database screen
/// directly via [ValueListenable].
@immutable
class DatabaseScreenState {
  const DatabaseScreenState({
    this.mode = DatabaseScreenMode.loading,
    this.definition,
    this.viewName,
    this.rows = const <DatabaseRow>[],
    this.nextCursor,
    this.isLoadingFirst = false,
    this.isLoadingMore = false,
    this.groups,
    this.columns,
    this.error,
    this.leftViewNotice,
  });

  static const initial = DatabaseScreenState();

  final DatabaseScreenMode mode;
  final DatabaseDefinition? definition;

  /// The name of the currently-selected view, resolved against
  /// [definition]'s views (falling back to the first view for an unknown
  /// name).
  final String? viewName;

  /// Current view's [ViewDefinition], looked up from [definition] and
  /// [viewName].
  ViewDefinition? get view {
    final def = definition;
    final name = viewName;
    if (def == null || name == null) return null;
    for (final v in def.views) {
      if (v.name == name) return v;
    }
    return def.views.isEmpty ? null : def.views.first;
  }

  /// Table/list rows. Unused for a board view — see [columns].
  final List<DatabaseRow> rows;
  final String? nextCursor;
  final bool isLoadingFirst;
  final bool isLoadingMore;

  /// Present only for a board view (or a grouped query), from the server's
  /// `groups`.
  final List<GroupCount>? groups;

  /// Present only for a board view: one entry per option (in option order)
  /// plus a trailing "No value" column.
  final List<BoardColumn>? columns;

  final Object? error;
  final LeftViewNotice? leftViewNotice;

  bool get hasMore => nextCursor != null;

  DatabaseScreenState copyWith({
    DatabaseScreenMode? mode,
    Object? definition = _sentinel,
    Object? viewName = _sentinel,
    List<DatabaseRow>? rows,
    Object? nextCursor = _sentinel,
    bool? isLoadingFirst,
    bool? isLoadingMore,
    Object? groups = _sentinel,
    Object? columns = _sentinel,
    Object? error = _sentinel,
    Object? leftViewNotice = _sentinel,
  }) {
    return DatabaseScreenState(
      mode: mode ?? this.mode,
      definition: identical(definition, _sentinel)
          ? this.definition
          : definition as DatabaseDefinition?,
      viewName: identical(viewName, _sentinel)
          ? this.viewName
          : viewName as String?,
      rows: rows ?? this.rows,
      nextCursor: identical(nextCursor, _sentinel)
          ? this.nextCursor
          : nextCursor as String?,
      isLoadingFirst: isLoadingFirst ?? this.isLoadingFirst,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      groups: identical(groups, _sentinel)
          ? this.groups
          : groups as List<GroupCount>?,
      columns: identical(columns, _sentinel)
          ? this.columns
          : columns as List<BoardColumn>?,
      error: identical(error, _sentinel) ? this.error : error,
      leftViewNotice: identical(leftViewNotice, _sentinel)
          ? this.leftViewNotice
          : leftViewNotice as LeftViewNotice?,
    );
  }
}

const Object _sentinel = Object();

/// One `DatabaseController` per open database screen (design.md), holding
/// the definition, the selected view, the row/column pages, and an
/// in-flight-patch map keyed by note id so optimistic edits can be
/// reverted.
///
/// Loads the definition through the shared [DatabasesController] cache so
/// it agrees with the sidebar and embeds. Subscribes to wildcard `changed`
/// events and debounces re-query to one per second.
class DatabaseController extends ValueNotifier<DatabaseScreenState> {
  DatabaseController({
    required RobotNotesClient api,
    required DatabasesController databases,
    required String databaseId,
    String? initialView,
    int pageSize = 50,
    int boardPageSize = 20,
    Stream<RealtimeEvent>? events,
    Future<void> Function(Duration)? debounceScheduler,
  }) : _api = api,
       _databases = databases,
       _databaseId = databaseId,
       _pageSize = pageSize,
       _boardPageSize = boardPageSize,
       _debounceScheduler = debounceScheduler ?? Future<void>.delayed,
       super(DatabaseScreenState.initial.copyWith(viewName: initialView)) {
    if (events != null) {
      _sub = events.listen(_onEvent);
    }
  }

  static const Duration debounceDuration = Duration(seconds: 1);

  /// The API client this controller was built with, for callers (a
  /// [PropertyEditor]'s relation picker) that need to build their own
  /// requests, such as a [TitleSearchService].
  RobotNotesClient get api => _api;

  final RobotNotesClient _api;
  final DatabasesController _databases;
  final String _databaseId;
  final int _pageSize;
  final int _boardPageSize;
  final Future<void> Function(Duration) _debounceScheduler;

  StreamSubscription<RealtimeEvent>? _sub;
  bool _disposed = false;
  int _debounceGen = 0;

  /// The property values as they stood before an in-flight or since-applied
  /// optimistic patch, keyed by note id — used both to revert on error and
  /// to build a [LeftViewNotice] for undo.
  final Map<String, Map<String, Object?>> _prePatchValues =
      <String, Map<String, Object?>>{};

  /// Loads the definition (via the shared cache) and the first page for the
  /// resolved view.
  Future<void> load() async {
    if (_disposed) return;
    value = value.copyWith(mode: DatabaseScreenMode.loading, error: null);
    final DatabaseDefinition def;
    try {
      def = await _databases.definition(_databaseId);
    } on NotFoundException {
      if (_disposed) return;
      value = value.copyWith(mode: DatabaseScreenMode.notFound);
      return;
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(mode: DatabaseScreenMode.error, error: e);
      return;
    }
    if (_disposed) return;
    final resolvedView = _resolveViewName(def, value.viewName);
    value = value.copyWith(definition: def, viewName: resolvedView);
    await _queryCurrentView();
  }

  /// Resolves [requested] against [def]'s views: an exact match wins,
  /// otherwise (including when [requested] is `null`) the first view
  /// applies — the "unknown view falls back to the default" rule.
  String? _resolveViewName(DatabaseDefinition def, String? requested) {
    if (def.views.isEmpty) return null;
    if (requested != null) {
      for (final v in def.views) {
        if (v.name == requested) return requested;
      }
    }
    return def.views.first.name;
  }

  /// Switches to view [name] (falling back to the default when unknown)
  /// and re-queries from scratch.
  Future<void> selectView(String name) async {
    if (_disposed) return;
    final def = value.definition;
    if (def == null) return;
    final resolved = _resolveViewName(def, name);
    value = value.copyWith(viewName: resolved);
    await _queryCurrentView();
  }

  Future<void> _queryCurrentView() async {
    final view = value.view;
    if (view == null) {
      value = value.copyWith(mode: DatabaseScreenMode.ready, rows: const []);
      return;
    }
    if (view.type == ViewType.board) {
      await _loadBoard(view);
    } else {
      await _loadFlatFirstPage(view);
    }
  }

  Future<void> _loadFlatFirstPage(ViewDefinition view) async {
    value = value.copyWith(isLoadingFirst: true, error: null);
    try {
      final page = await _api.queryDatabase(
        _databaseId,
        view: view.name,
        limit: _pageSize,
      );
      if (_disposed) return;
      value = value.copyWith(
        mode: DatabaseScreenMode.ready,
        rows: page.items,
        nextCursor: page.nextCursor,
        groups: page.groups,
        columns: null,
        isLoadingFirst: false,
      );
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(
        mode: DatabaseScreenMode.error,
        isLoadingFirst: false,
        error: e,
      );
    }
  }

  /// Loads the next page for a table/list view.
  Future<void> loadMore() async {
    if (_disposed) return;
    final view = value.view;
    if (view == null || view.type == ViewType.board) return;
    if (value.isLoadingMore || !value.hasMore) return;
    value = value.copyWith(isLoadingMore: true, error: null);
    try {
      final page = await _api.queryDatabase(
        _databaseId,
        view: view.name,
        limit: _pageSize,
        after: value.nextCursor,
      );
      if (_disposed) return;
      value = value.copyWith(
        rows: <DatabaseRow>[...value.rows, ...page.items],
        nextCursor: page.nextCursor,
        isLoadingMore: false,
      );
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(isLoadingMore: false, error: e);
    }
  }

  Future<void> _loadBoard(ViewDefinition view) async {
    value = value.copyWith(isLoadingFirst: true, error: null);
    final groupBy = view.groupBy;
    if (groupBy == null) {
      // No grouping property declared — nothing to build columns from;
      // surface as an (empty) board rather than crash.
      value = value.copyWith(
        mode: DatabaseScreenMode.ready,
        rows: const [],
        columns: const [],
        isLoadingFirst: false,
      );
      return;
    }
    try {
      final counts = await _api.queryDatabase(
        _databaseId,
        view: view.name,
        groupBy: groupBy,
        limit: 1,
      );
      if (_disposed) return;
      final groups = counts.groups ?? const <GroupCount>[];
      final options =
          value.definition?.properties[groupBy]?.options ?? const <String>[];
      final specs = <BoardColumn>[
        for (final option in options)
          BoardColumn(
            label: option,
            value: option,
            count: _countFor(groups, option),
          ),
        BoardColumn(
          label: 'No value',
          value: null,
          isNoValue: true,
          count: _countFor(groups, null),
        ),
      ];
      value = value.copyWith(groups: groups, columns: specs);
      final loaded = await Future.wait(
        specs.map((c) => _fetchColumnPage(view, c, after: null)),
      );
      if (_disposed) return;
      value = value.copyWith(
        mode: DatabaseScreenMode.ready,
        columns: loaded,
        isLoadingFirst: false,
      );
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(
        mode: DatabaseScreenMode.error,
        isLoadingFirst: false,
        error: e,
      );
    }
  }

  int _countFor(List<GroupCount> groups, Object? value) {
    for (final g in groups) {
      if (g.value == value) return g.count;
    }
    return 0;
  }

  Filter _columnFilter(ViewDefinition view, BoardColumn column) {
    final condition = column.isNoValue
        ? Condition(property: view.groupBy!, op: FilterOp.isEmpty)
        : Condition(
            property: view.groupBy!,
            op: FilterOp.eq,
            value: column.value,
          );
    final viewFilter = view.filter;
    return viewFilter == null ? condition : And([viewFilter, condition]);
  }

  Future<BoardColumn> _fetchColumnPage(
    ViewDefinition view,
    BoardColumn column, {
    required String? after,
  }) async {
    final page = await _api.queryDatabase(
      _databaseId,
      filter: _columnFilter(view, column),
      sort: view.sort,
      limit: _boardPageSize,
      after: after,
    );
    return column.copyWith(
      items: after == null
          ? page.items
          : <DatabaseRow>[...column.items, ...page.items],
      nextCursor: page.nextCursor,
      isLoadingMore: false,
    );
  }

  /// Loads the next page for the board column labelled [columnValue] (the
  /// option string, or `null` for "No value").
  Future<void> loadMoreColumn(Object? columnValue) async {
    if (_disposed) return;
    final view = value.view;
    final columns = value.columns;
    if (view == null || columns == null) return;
    final idx = columns.indexWhere((c) => c.value == columnValue);
    if (idx < 0) return;
    final column = columns[idx];
    if (column.isLoadingMore || !column.hasMore) return;
    value = value.copyWith(
      columns: _replaceColumn(
        columns,
        idx,
        column.copyWith(isLoadingMore: true),
      ),
    );
    try {
      final updated = await _fetchColumnPage(
        view,
        column,
        after: column.nextCursor,
      );
      if (_disposed) return;
      final current = value.columns;
      if (current == null) return;
      final curIdx = current.indexWhere((c) => c.value == columnValue);
      if (curIdx < 0) return;
      value = value.copyWith(columns: _replaceColumn(current, curIdx, updated));
    } on ApiException catch (e) {
      if (_disposed) return;
      final current = value.columns;
      if (current == null) return;
      final curIdx = current.indexWhere((c) => c.value == columnValue);
      if (curIdx >= 0) {
        value = value.copyWith(
          columns: _replaceColumn(
            current,
            curIdx,
            current[curIdx].copyWith(isLoadingMore: false),
          ),
          error: e,
        );
      }
    }
  }

  List<BoardColumn> _replaceColumn(
    List<BoardColumn> columns,
    int index,
    BoardColumn replacement,
  ) {
    return <BoardColumn>[
      ...columns.take(index),
      replacement,
      ...columns.skip(index + 1),
    ];
  }

  /// Applies a property patch optimistically to whichever row/card carries
  /// [noteId] — updating [set] keys and removing [unset] keys locally —
  /// then sends `PATCH /notes/{id}/properties`. On success the row/card
  /// keeps the optimistic value (it stays in place even if it now falls
  /// outside the view's filter — design.md's "left the view" rule — until
  /// the next re-query notices and removes it). On a `validation_failed`
  /// (400) the local value is reverted and the error is left on
  /// [DatabaseScreenState.error] for the caller to surface next to the
  /// cell. Returns `null` on success, or the server's message (falling
  /// back to a generic one) on failure, matching [PropertyCommitCallback]
  /// so a [PropertyEditor] can be handed a thin wrapper around this call.
  Future<String?> patchProperty(
    String noteId, {
    Map<String, Object?>? set,
    List<String>? unset,
  }) async {
    if (_disposed) return null;
    final previous = _currentPropertiesOf(noteId);
    if (previous == null) return null;
    final title = _currentTitleOf(noteId) ?? '';
    _prePatchValues[noteId] = previous;
    _applyLocalPatch(noteId, set: set, unset: unset);
    try {
      await _api.patchProperties(noteId, set: set, unset: unset);
      // Success: the optimistic value stands. Whether it left the view is
      // decided by the next re-query, per design.md. Remember the
      // pre-patch value in case it did, so an undo can restore it.
      _rememberForUndo(noteId, title, previous, set);
      return null;
    } on ApiException catch (e) {
      if (_disposed) return null;
      _applyLocalPatch(
        noteId,
        set: previous,
        unset: (set?.keys.toList() ?? const <String>[])
            .where((k) => !previous.containsKey(k))
            .toList(),
      );
      value = value.copyWith(error: e);
      return describeError(e, fallback: 'Could not save.');
    } finally {
      _prePatchValues.remove(noteId);
    }
  }

  String? _currentTitleOf(String noteId) {
    for (final row in value.rows) {
      if (row.id == noteId) return row.title;
    }
    final columns = value.columns;
    if (columns != null) {
      for (final column in columns) {
        for (final row in column.items) {
          if (row.id == noteId) return row.title;
        }
      }
    }
    return null;
  }

  Map<String, Object?>? _currentPropertiesOf(String noteId) {
    for (final row in value.rows) {
      if (row.id == noteId) return Map<String, Object?>.of(row.properties);
    }
    final columns = value.columns;
    if (columns != null) {
      for (final column in columns) {
        for (final row in column.items) {
          if (row.id == noteId) {
            return Map<String, Object?>.of(row.properties);
          }
        }
      }
    }
    return null;
  }

  void _applyLocalPatch(
    String noteId, {
    Map<String, Object?>? set,
    List<String>? unset,
  }) {
    DatabaseRow apply(DatabaseRow row) {
      if (row.id != noteId) return row;
      final props = Map<String, Object?>.of(row.properties);
      if (set != null) props.addAll(set);
      if (unset != null) {
        for (final key in unset) {
          props.remove(key);
        }
      }
      return DatabaseRow(
        id: row.id,
        title: row.title,
        path: row.path,
        version: row.version,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        tags: row.tags,
        properties: props,
        invalid: row.invalid,
      );
    }

    final rows = value.rows.map(apply).toList(growable: false);
    final columns = value.columns
        ?.map(
          (c) => c.copyWith(items: c.items.map(apply).toList(growable: false)),
        )
        .toList(growable: false);
    value = value.copyWith(rows: rows, columns: columns);
  }

  /// Board drag: moves the card for [noteId] to [columnValue] (`null` for
  /// "No value") by patching the view's `group_by` property.
  Future<void> moveCard(String noteId, Object? columnValue) async {
    final view = value.view;
    if (view?.groupBy == null) return;
    final property = view!.groupBy!;
    if (columnValue == null) {
      await patchProperty(noteId, unset: [property]);
    } else {
      await patchProperty(noteId, set: {property: columnValue});
    }
  }

  /// The database id this controller is open on, for callers building the
  /// "New row" flow (task 5.5) that need it for navigation or display.
  String get databaseId => _databaseId;

  /// `POST /databases/{id}/rows` with just a title — the "New row" flow
  /// (task 5.5). The caller navigates to the created note; this controller
  /// doesn't add it to [DatabaseScreenState.rows]/[columns] itself, since
  /// the next `changed`-triggered re-query (or the view re-query on
  /// return) picks it up the same way any other row would.
  Future<Note> createRow(String title) =>
      _api.createRow(_databaseId, title: title);

  /// Clears the current "left the view" notice, e.g. once its undo action
  /// has been taken or the user dismissed it.
  void dismissLeftViewNotice() {
    if (value.leftViewNotice == null) return;
    value = value.copyWith(leftViewNotice: null);
  }

  void _onEvent(RealtimeEvent event) {
    if (event is! RealtimeMessage) return;
    if (event.message is! ChangedEvent) return;
    _scheduleDebouncedRequery();
  }

  void _scheduleDebouncedRequery() {
    _debounceGen += 1;
    final gen = _debounceGen;
    unawaited(_runDebounced(gen));
  }

  Future<void> _runDebounced(int gen) async {
    await _debounceScheduler(debounceDuration);
    if (_disposed) return;
    if (_debounceGen != gen) return;
    await _requery();
  }

  /// Re-runs the current query, detecting rows that vanished (left the
  /// view) for a note this controller just optimistically patched, and
  /// surfacing a [LeftViewNotice] with undo for the first one found.
  Future<void> _requery() async {
    final view = value.view;
    if (view == null) return;
    final previousIds = _allRowIds();
    if (view.type == ViewType.board) {
      await _loadBoard(view);
    } else {
      await _loadFlatFirstPage(view);
    }
    if (_disposed) return;
    final currentIds = _allRowIds();
    for (final id in previousIds) {
      if (currentIds.contains(id)) continue;
      final pre = _previousPropertiesForNotice(id);
      if (pre == null) continue;
      _leftViewCandidates.remove(id);
      value = value.copyWith(
        leftViewNotice: LeftViewNotice(
          noteId: id,
          title: pre.title,
          previousSet: pre.set,
          previousUnset: pre.unset,
        ),
      );
      break;
    }
  }

  Set<String> _allRowIds() {
    final ids = <String>{for (final r in value.rows) r.id};
    final columns = value.columns;
    if (columns != null) {
      for (final c in columns) {
        ids.addAll(c.items.map((r) => r.id));
      }
    }
    return ids;
  }

  /// The pre-patch snapshot recorded for a still-outstanding notice; kept
  /// separately from [_prePatchValues] (which is cleared once each patch
  /// settles) via [_leftViewCandidates].
  _NoticeSource? _previousPropertiesForNotice(String noteId) =>
      _leftViewCandidates[noteId];

  final Map<String, _NoticeSource> _leftViewCandidates =
      <String, _NoticeSource>{};

  /// Records the pre-patch value so a later disappearance can be undone.
  /// Called by [patchProperty] right after the optimistic apply succeeds
  /// remotely — see below where it hooks in.
  void _rememberForUndo(
    String noteId,
    String title,
    Map<String, Object?> previous,
    Map<String, Object?>? set,
  ) {
    final unset = set?.keys.toList() ?? const <String>[];
    _leftViewCandidates[noteId] = _NoticeSource(
      title: title,
      set: previous,
      unset: unset,
    );
  }

  /// Re-applies the value recorded in the current [LeftViewNotice] and
  /// dismisses it.
  Future<void> undoLeftView() async {
    final notice = value.leftViewNotice;
    if (notice == null) return;
    dismissLeftViewNotice();
    await _api.patchProperties(
      notice.noteId,
      set: notice.previousSet.isEmpty ? null : notice.previousSet,
      unset: notice.previousUnset.isEmpty ? null : notice.previousUnset,
    );
    await _requery();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}

@immutable
class _NoticeSource {
  const _NoticeSource({
    required this.title,
    required this.set,
    required this.unset,
  });

  final String title;
  final Map<String, Object?> set;
  final List<String> unset;
}
