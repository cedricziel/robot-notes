import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../api/api_client.dart';
import '../realtime/ws_client.dart';

/// Snapshot of [DatabasesController] state. Backs the sidebar's Databases
/// section and embed title resolution.
@immutable
class DatabasesState {
  const DatabasesState({
    this.items = const <DatabaseSummary>[],
    this.isLoading = false,
    this.error,
  });

  static const empty = DatabasesState();

  /// Every registered database, from `GET /databases`.
  final List<DatabaseSummary> items;
  final bool isLoading;

  /// The last error from [DatabasesController.refresh]. Cleared on the
  /// next successful refresh.
  final Object? error;

  DatabasesState copyWith({
    List<DatabaseSummary>? items,
    bool? isLoading,
    Object? error = _sentinel,
  }) {
    return DatabasesState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: identical(error, _sentinel) ? this.error : error,
    );
  }
}

const Object _sentinel = Object();

/// Drives the sidebar's Databases section and serves as the shared cache
/// of full [DatabaseDefinition]s that the database screen, the property
/// panel, and embeds all read from (design.md: "the client-side rule").
///
/// Fetches `GET /databases` for the listing and `GET /databases/{id}` for
/// individual definitions, filled on demand and kept until the next
/// refresh. A wildcard `changed` event (any note may be a database
/// definition) triggers a debounced refresh — one per second at most —
/// which also invalidates the definition cache so the next lookup picks
/// up server-side changes.
class DatabasesController extends ValueNotifier<DatabasesState> {
  DatabasesController({
    required RobotNotesClient api,
    Stream<RealtimeEvent>? events,
    Future<void> Function(Duration)? debounceScheduler,
  }) : _api = api,
       _debounceScheduler = debounceScheduler ?? Future<void>.delayed,
       super(DatabasesState.empty) {
    if (events != null) {
      _sub = events.listen(_onEvent);
    }
  }

  /// How long a `changed` event waits before triggering a refresh; further
  /// events arriving in that window coalesce into the same pending refresh.
  static const Duration debounceDuration = Duration(seconds: 1);

  final RobotNotesClient _api;
  final Future<void> Function(Duration) _debounceScheduler;

  StreamSubscription<RealtimeEvent>? _sub;
  bool _disposed = false;
  int _debounceGen = 0;
  Future<void>? _refreshInFlight;

  final Map<String, DatabaseDefinition> _definitionCache =
      <String, DatabaseDefinition>{};

  /// Re-fetches the list. Concurrent calls coalesce into one request.
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    return _refreshInFlight ??= _doRefresh();
  }

  Future<void> _doRefresh() async {
    value = value.copyWith(isLoading: true, error: null);
    try {
      final list = await _api.listDatabases();
      if (_disposed) return;
      // The listing just told us the ground truth may have moved; the
      // definitions we cached from before are no longer trustworthy.
      _definitionCache.clear();
      value = value.copyWith(items: list.items, isLoading: false);
    } catch (e) {
      if (_disposed) return;
      value = value.copyWith(isLoading: false, error: e);
    } finally {
      _refreshInFlight = null;
    }
  }

  /// The full definition for [id]. Serves the cached copy unless
  /// [forceRefresh] is set or nothing is cached yet, in which case it
  /// fetches `GET /databases/{id}` and caches the result.
  Future<DatabaseDefinition> definition(
    String id, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = _definitionCache[id];
      if (cached != null) return cached;
    }
    final def = await _api.getDatabase(id);
    if (!_disposed) _definitionCache[id] = def;
    return def;
  }

  /// The cached definition for [id], or `null` if nothing has been fetched
  /// (or a refresh has since invalidated it) — synchronous, for widgets
  /// that only want to render when the cache is already warm.
  DatabaseDefinition? cachedDefinition(String id) => _definitionCache[id];

  /// Finds the loaded [DatabaseSummary] whose title matches [title],
  /// Unicode-NFC-normalized and compared case-insensitively — the same
  /// normalization the server applies to titles on write (see
  /// `server/lib/src/note_path.dart`), so an embed spelled with a
  /// differently-composed accent still resolves. Returns `null` when no
  /// database is loaded with that title.
  DatabaseSummary? resolveByTitle(String title) {
    final needle = _normalize(title);
    for (final item in value.items) {
      if (_normalize(item.title) == needle) return item;
    }
    return null;
  }

  String _normalize(String s) => unorm.nfc(s).toLowerCase();

  void _onEvent(RealtimeEvent event) {
    if (event is! RealtimeMessage) return;
    if (event.message is! ChangedEvent) return;
    // Any changed note could be a database definition — cheaper to
    // debounce and re-list than to track which notes are definitions.
    _scheduleDebouncedRefresh();
  }

  void _scheduleDebouncedRefresh() {
    _debounceGen += 1;
    final gen = _debounceGen;
    unawaited(_runDebounced(gen));
  }

  Future<void> _runDebounced(int gen) async {
    await _debounceScheduler(debounceDuration);
    if (_disposed) return;
    if (_debounceGen != gen) return;
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
