import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';

/// Snapshot of [NotesSearchController] state.
@immutable
class SearchState {
  const SearchState({
    this.query = '',
    this.hits = const <SearchHit>[],
    this.isLoading = false,
    this.error,
  });

  static const empty = SearchState();

  final String query;
  final List<SearchHit> hits;
  final bool isLoading;
  final ApiException? error;

  SearchState copyWith({
    String? query,
    List<SearchHit>? hits,
    bool? isLoading,
    Object? error = _sentinel,
  }) =>
      SearchState(
        query: query ?? this.query,
        hits: hits ?? this.hits,
        isLoading: isLoading ?? this.isLoading,
        error:
            identical(error, _sentinel) ? this.error : error as ApiException?,
      );
}

const Object _sentinel = Object();

/// Drives the search view: debounces input, calls `GET /search`, and
/// surfaces hits to the UI.
///
/// `setQuery` is the only entry point. Empty/whitespace input clears the
/// previous results and *cancels* any pending request — the server is
/// never asked for an empty term. A non-empty query schedules a fetch
/// after [debounce]; subsequent calls within that window cancel the
/// previous schedule so we issue one request per pause, not one per
/// keystroke.
class NotesSearchController extends ValueNotifier<SearchState> {
  NotesSearchController({
    required RobotNotesClient api,
    Duration debounce = const Duration(milliseconds: 250),
    Future<void> Function(Duration)? scheduler,
  })  : _api = api,
        _debounce = debounce,
        _scheduler = scheduler ?? Future<void>.delayed,
        super(SearchState.empty);

  final RobotNotesClient _api;
  final Duration _debounce;
  final Future<void> Function(Duration) _scheduler;
  int _gen = 0;
  bool _disposed = false;

  void setQuery(String q) {
    if (_disposed) return;
    final trimmed = q.trim();
    _gen += 1;
    final myGen = _gen;
    if (trimmed.isEmpty) {
      // Cancel any in-flight schedule by bumping the generation; clear
      // results so the UI shows the empty state again.
      value = const SearchState();
      return;
    }
    value = value.copyWith(query: q, isLoading: true, error: null);
    unawaited(_runSearch(myGen, trimmed));
  }

  Future<void> _runSearch(int gen, String q) async {
    await _scheduler(_debounce);
    if (_disposed) return;
    if (gen != _gen) return;
    try {
      final hits = await _api.search(q: q);
      if (_disposed) return;
      if (gen != _gen) return;
      value = value.copyWith(hits: hits, isLoading: false);
    } on ApiException catch (e) {
      if (_disposed) return;
      if (gen != _gen) return;
      value = value.copyWith(isLoading: false, error: e);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _gen += 1;
    super.dispose();
  }
}
