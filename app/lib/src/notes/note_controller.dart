import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../realtime/ws_client.dart';

/// High-level state of a single open note.
enum NoteMode {
  /// `GET /notes/{id}` is in flight; nothing to render yet.
  loading,

  /// We have the note; we are not editing. Either no one holds the lock,
  /// or someone else does.
  viewing,

  /// `POST /notes/{id}/lock` is in flight.
  acquiringLock,

  /// We hold the lock; UI presents an editable buffer.
  editing,

  /// `PUT /notes/{id}` is in flight.
  saving,

  /// Last save returned 409. The user must accept the server's version,
  /// keep their own (force overwrite), or cancel out of edit mode.
  conflict,

  /// `DELETE /notes/{id}` is in flight.
  deleting,

  /// `PUT /notes/{id}` with a new `path` is in flight.
  moving,

  /// `DELETE /notes/{id}` succeeded (or the note was already gone). Terminal;
  /// the view should close.
  deleted,
}

/// Snapshot of [NoteController] state. Drives the view directly.
@immutable
class NoteState {
  const NoteState({
    this.mode = NoteMode.loading,
    this.note,
    this.lock,
    this.viewers = const <String>[],
    this.editTitle,
    this.editContent,
    this.error,
    this.conflictCurrent,
    this.lockedByOtherBanner,
    this.backlinks = const <BacklinkHit>[],
    this.backlinksLoading = false,
  });

  static const initial = NoteState();

  final NoteMode mode;
  final Note? note;

  /// Most recently observed lock state for the open note.
  final Lock? lock;
  final List<String> viewers;

  /// Local edit buffers. Non-null only while [mode] is [NoteMode.editing] or
  /// [NoteMode.conflict].
  final String? editTitle;
  final String? editContent;

  final ApiException? error;

  /// Body of the 409 response — what the server says the note currently
  /// looks like. Used by the conflict UI.
  final Note? conflictCurrent;

  /// Set when the lock was lost mid-edit (heartbeat 404/423 or `lock` event
  /// for another holder). UI surfaces this as a banner over a read-only view.
  final String? lockedByOtherBanner;

  /// Notes that link to this one, from `GET /notes/{id}/backlinks`. Loaded
  /// alongside the note itself; empty (never an error state) when there are
  /// none or the fetch failed — the backlinks panel renders that as an
  /// empty state, not an error.
  final List<BacklinkHit> backlinks;
  final bool backlinksLoading;

  /// True while the edit buffers differ from the loaded note.
  bool get isDirty {
    final note = this.note;
    if (note == null) return false;
    if (mode != NoteMode.editing && mode != NoteMode.conflict) return false;
    return editTitle != note.title || editContent != note.content;
  }

  NoteState copyWith({
    NoteMode? mode,
    Object? note = _sentinel,
    Object? lock = _sentinel,
    List<String>? viewers,
    Object? editTitle = _sentinel,
    Object? editContent = _sentinel,
    Object? error = _sentinel,
    Object? conflictCurrent = _sentinel,
    Object? lockedByOtherBanner = _sentinel,
    List<BacklinkHit>? backlinks,
    bool? backlinksLoading,
  }) {
    return NoteState(
      mode: mode ?? this.mode,
      note: identical(note, _sentinel) ? this.note : note as Note?,
      lock: identical(lock, _sentinel) ? this.lock : lock as Lock?,
      viewers: viewers ?? this.viewers,
      editTitle: identical(editTitle, _sentinel)
          ? this.editTitle
          : editTitle as String?,
      editContent: identical(editContent, _sentinel)
          ? this.editContent
          : editContent as String?,
      error: identical(error, _sentinel) ? this.error : error as ApiException?,
      conflictCurrent: identical(conflictCurrent, _sentinel)
          ? this.conflictCurrent
          : conflictCurrent as Note?,
      backlinks: backlinks ?? this.backlinks,
      backlinksLoading: backlinksLoading ?? this.backlinksLoading,
      lockedByOtherBanner: identical(lockedByOtherBanner, _sentinel)
          ? this.lockedByOtherBanner
          : lockedByOtherBanner as String?,
    );
  }
}

const Object _sentinel = Object();

/// Drives a single note's view. Loads via HTTP, applies live updates from
/// the realtime stream, manages the editor lock (acquire / heartbeat /
/// release), and handles the 409 / 423 reconcile cases.
///
/// All side effects (HTTP, scheduled heartbeats, subscribe/unsubscribe)
/// route through injected callbacks so widget tests stay deterministic
/// and offline.
class NoteController extends ValueNotifier<NoteState> {
  NoteController({
    required RobotNotesClient api,
    required String noteId,
    required String actor,
    Stream<RealtimeEvent>? events,
    void Function(String noteId)? onSubscribe,
    void Function(String noteId)? onUnsubscribe,
    DateTime Function()? clock,
    Duration Function(Lock lock, DateTime now)? heartbeatInterval,
    Future<void> Function(Duration)? scheduler,
    Future<void> Function(Duration)? autosaveScheduler,
  }) : _api = api,
       _noteId = noteId,
       _actor = actor,
       _onSubscribe = onSubscribe,
       _onUnsubscribe = onUnsubscribe,
       _now = clock ?? DateTime.now,
       _heartbeatInterval = heartbeatInterval ?? _defaultHeartbeatInterval,
       _scheduler = scheduler ?? Future<void>.delayed,
       _autosaveScheduler = autosaveScheduler ?? Future<void>.delayed,
       super(NoteState.initial) {
    if (events != null) {
      _sub = events.listen(_onEvent);
    }
  }

  static Duration _defaultHeartbeatInterval(Lock lock, DateTime now) {
    final remaining = lock.expiresAt.difference(now);
    if (remaining <= Duration.zero) return Duration.zero;
    return Duration(microseconds: remaining.inMicroseconds ~/ 2);
  }

  /// How long after the last edit an automatic save fires.
  static const Duration autosaveDebounce = Duration(seconds: 2);

  final RobotNotesClient _api;
  final String _noteId;
  final String _actor;
  final void Function(String)? _onSubscribe;
  final void Function(String)? _onUnsubscribe;
  final DateTime Function() _now;
  final Duration Function(Lock, DateTime) _heartbeatInterval;
  final Future<void> Function(Duration) _scheduler;
  final Future<void> Function(Duration) _autosaveScheduler;

  StreamSubscription<RealtimeEvent>? _sub;
  bool _disposed = false;
  int _heartbeatGen = 0;
  int _autosaveGen = 0;

  /// Bumped for every note fetch after the initial [open] ([reload] and
  /// the realtime-triggered refetch), so a response that lands after a
  /// newer fetch started is dropped instead of overwriting the newer
  /// state. [open] stays outside it: nothing commits before the note has
  /// loaded, so it cannot be overtaken.
  int _noteFetchGen = 0;

  /// Bumped whenever a realtime lock event updates [NoteState.lock]. A
  /// note response that started before the event keeps the event's lock
  /// rather than replacing it with the older one the server embedded.
  int _lockGen = 0;

  /// Bumped for every backlinks fetch, which runs unawaited beside the
  /// note fetch and so can be in flight more than once.
  int _backlinksGen = 0;

  /// Loads the note and tells the realtime layer to subscribe so we receive
  /// `presence`, `lock`, and `changed` events for it.
  Future<void> open() async {
    if (_disposed) return;
    _onSubscribe?.call(_noteId);
    try {
      final note = await _api.getNote(_noteId);
      if (_disposed) return;
      value = value.copyWith(
        mode: NoteMode.viewing,
        note: note,
        lock: note.lock,
      );
      unawaited(_loadBacklinks());
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(error: e);
    }
  }

  /// Re-fetches the note and its backlinks (pull-to-refresh) without
  /// re-subscribing to its realtime events. Only meaningful while viewing:
  /// in any other mode the edit buffers or an in-flight lock acquisition
  /// own the note, so this is a no-op — including when the user enters
  /// edit mode while the fetch is still in flight. A failure lands in
  /// [NoteState.error] and leaves the already-loaded note on screen.
  Future<void> reload() async {
    if (_disposed) return;
    if (value.mode != NoteMode.viewing) return;
    final gen = ++_noteFetchGen;
    final lockGen = _lockGen;
    value = value.copyWith(error: null);
    try {
      final note = await _api.getNote(_noteId);
      if (!_canCommitNoteFetch(gen)) return;
      _commitFetchedNote(note, lockGen: lockGen);
      unawaited(_loadBacklinks());
    } on ApiException catch (e) {
      // A failure from a fetch that has since been superseded (or that
      // finished after the user entered edit mode) is not this reload's
      // to report.
      if (!_canCommitNoteFetch(gen)) return;
      value = value.copyWith(error: e);
    }
  }

  /// Whether a note fetch started at [gen] may still write its result:
  /// the controller is alive, no newer fetch has started, and the user is
  /// still viewing (edit buffers and lock acquisition own the note
  /// otherwise).
  bool _canCommitNoteFetch(int gen) =>
      !_disposed && gen == _noteFetchGen && value.mode == NoteMode.viewing;

  /// Writes a fetched [note], keeping the lock a realtime event set while
  /// the fetch was in flight (identified by [lockGen]) over the older one
  /// embedded in the response.
  void _commitFetchedNote(Note note, {required int lockGen}) {
    value = value.copyWith(
      note: note,
      lock: lockGen == _lockGen ? note.lock : value.lock,
    );
  }

  /// Loads notes that link to this one for the backlinks panel. Best-effort:
  /// a failure just leaves the list empty (the panel's empty state and an
  /// error state look the same to the user — there's nothing actionable to
  /// tell them apart), rather than surfacing via [NoteState.error].
  Future<void> _loadBacklinks() async {
    if (_disposed) return;
    final gen = ++_backlinksGen;
    value = value.copyWith(backlinksLoading: true);
    try {
      final hits = await _api.getBacklinks(_noteId);
      if (_disposed || gen != _backlinksGen) return;
      value = value.copyWith(backlinks: hits, backlinksLoading: false);
    } catch (_) {
      // Best-effort: the panel's empty state and "couldn't load" would look
      // identical to the user, so any failure (network, decode, ...) just
      // leaves the list empty rather than surfacing via NoteState.error.
      if (_disposed || gen != _backlinksGen) return;
      value = value.copyWith(backlinksLoading: false);
    }
  }

  /// Looks up note titles matching [query] for the `[[`-link autocomplete,
  /// via `GET /search`. Returns no titles (and issues no request) for a
  /// blank query, and swallows request failures — autocomplete has nothing
  /// useful to show for an error beyond "no matches".
  Future<List<String>> searchLinkTitles(String query) async {
    if (query.trim().isEmpty) return const <String>[];
    try {
      final hits = await _api.search(q: query);
      return <String>{for (final h in hits) h.title}.toList();
    } on ApiException {
      return const <String>[];
    }
  }

  /// Asks the server for the editor lock. On success re-fetches the note so
  /// the edit buffers start from the state as it exists under the lock, then
  /// transitions to [NoteMode.editing] and schedules the heartbeat loop. On
  /// 423 surfaces the holder via [NoteState.lock] but stays read-only.
  Future<void> enterEditMode() async {
    if (_disposed) return;
    if (value.mode != NoteMode.viewing) return;
    value = value.copyWith(mode: NoteMode.acquiringLock, error: null);
    final Lock acquired;
    try {
      acquired = await _api.acquireLock(_noteId);
    } on LockedException catch (e) {
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.viewing, lock: e.lock, error: e);
      return;
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.viewing, error: e);
      return;
    }
    if (_disposed) return;
    // The lock serialises writers, so the copy loaded when the screen opened
    // may be stale by now; editing from it would turn every save into a 409.
    final Note note;
    try {
      note = await _api.getNote(_noteId);
    } on ApiException catch (e) {
      await _releaseLockBestEffort();
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.viewing, lock: null, error: e);
      return;
    }
    if (_disposed) return;
    value = value.copyWith(
      mode: NoteMode.editing,
      note: note,
      lock: acquired,
      editTitle: note.title,
      editContent: note.content,
      lockedByOtherBanner: null,
    );
    _scheduleHeartbeat(acquired);
  }

  void setEditTitle(String title) {
    if (value.mode != NoteMode.editing && value.mode != NoteMode.conflict) {
      return;
    }
    value = value.copyWith(editTitle: title);
    _scheduleAutosave();
  }

  void setEditContent(String content) {
    if (value.mode != NoteMode.editing && value.mode != NoteMode.conflict) {
      return;
    }
    value = value.copyWith(editContent: content);
    _scheduleAutosave();
  }

  /// Cancels any autosave scheduled by a prior edit, without affecting the
  /// heartbeat. Callers that are about to save explicitly (button tap,
  /// keyboard shortcut, or the close-flush) call this first so a
  /// coincidentally-due autosave doesn't also fire and race a second save.
  void cancelPendingAutosave() {
    _autosaveGen += 1;
  }

  /// Schedules a debounced autosave [autosaveDebounce] after the most
  /// recent edit. Only ever schedules while [NoteMode.editing] — edits
  /// made from the conflict view are resolved explicitly ("Use server
  /// version" / "Save mine"), never autosaved.
  void _scheduleAutosave() {
    if (value.mode != NoteMode.editing) return;
    _autosaveGen += 1;
    final gen = _autosaveGen;
    unawaited(_runAutosave(gen));
  }

  Future<void> _runAutosave(int gen) async {
    await _autosaveScheduler(autosaveDebounce);
    if (_disposed) return;
    if (_autosaveGen != gen) return;
    if (value.mode != NoteMode.editing) return;
    if (!value.isDirty) return;
    await save();
  }

  /// Sends `PUT /notes/{id}` with the last-loaded version as `If-Match`.
  /// Routes 409 → [NoteMode.conflict], 423 → forced read-only with banner.
  Future<void> save() async {
    if (_disposed) return;
    if (value.mode != NoteMode.editing && value.mode != NoteMode.conflict) {
      return;
    }
    final note = value.note;
    if (note == null) return;
    final title = value.editTitle ?? note.title;
    final content = value.editContent ?? note.content;
    value = value.copyWith(mode: NoteMode.saving, error: null);
    try {
      final updated = await _api.updateNote(
        id: _noteId,
        title: title,
        content: content,
        ifMatch: note.version,
      );
      if (_disposed) return;
      // Stay in editing mode so the user can keep typing without having to
      // re-acquire the lock. Sync the local note + buffers to the saved
      // server state.
      value = value.copyWith(
        mode: NoteMode.editing,
        note: updated,
        editTitle: updated.title,
        editContent: updated.content,
        conflictCurrent: null,
      );
    } on VersionConflictException catch (e) {
      if (_disposed) return;
      value = value.copyWith(
        mode: NoteMode.conflict,
        conflictCurrent: e.current,
        error: e,
      );
    } on LockedException catch (e) {
      if (_disposed) return;
      _stopHeartbeat();
      value = value.copyWith(
        mode: NoteMode.viewing,
        lock: e.lock,
        editTitle: null,
        editContent: null,
        lockedByOtherBanner:
            'Editing taken over by ${e.lock.holder}. You are now read-only.',
        error: e,
      );
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.editing, error: e);
    }
  }

  /// Discard local edits in favour of the server's current state. Stays in
  /// editing mode so the user can keep working from the new baseline.
  void resolveConflictAcceptServer() {
    if (value.mode != NoteMode.conflict) return;
    final current = value.conflictCurrent;
    if (current == null) return;
    value = value.copyWith(
      mode: NoteMode.editing,
      note: current,
      editTitle: current.title,
      editContent: current.content,
      conflictCurrent: null,
      error: null,
    );
  }

  /// Force-overwrite: bump the local note's version to the server's current
  /// version and re-issue the save.
  Future<void> resolveConflictKeepMine() async {
    if (value.mode != NoteMode.conflict) return;
    final current = value.conflictCurrent;
    if (current == null) return;
    value = value.copyWith(
      mode: NoteMode.editing,
      note: current,
      conflictCurrent: null,
      error: null,
    );
    await save();
  }

  /// Releases the lock and exits edit mode. Always best-effort: if the
  /// server returns an error the UI still flips back to viewing.
  Future<void> exitEditing() async {
    if (_disposed) return;
    if (value.mode != NoteMode.editing && value.mode != NoteMode.conflict) {
      return;
    }
    _stopHeartbeat();
    await _releaseLockBestEffort();
    if (_disposed) return;
    value = value.copyWith(
      mode: NoteMode.viewing,
      lock: null,
      editTitle: null,
      editContent: null,
      conflictCurrent: null,
    );
  }

  Future<void> _releaseLockBestEffort() async {
    try {
      await _api.releaseLock(_noteId);
    } on ApiException {
      // The server will expire the lock by TTL anyway.
    }
  }

  void _scheduleHeartbeat(Lock lock) {
    _heartbeatGen += 1;
    final gen = _heartbeatGen;
    final delay = _heartbeatInterval(lock, _now());
    // Fire-and-forget: the loop chains future heartbeats off each successful
    // PUT. A new acquire (or stop) bumps `_heartbeatGen` so any in-flight
    // delay becomes a no-op when it resolves.
    unawaited(_runHeartbeat(gen, delay));
  }

  Future<void> _runHeartbeat(int gen, Duration delay) async {
    await _scheduler(delay);
    if (_disposed) return;
    if (_heartbeatGen != gen) return;
    if (value.mode != NoteMode.editing && value.mode != NoteMode.saving) {
      return;
    }
    try {
      final lock = await _api.heartbeatLock(_noteId);
      if (_disposed) return;
      if (_heartbeatGen != gen) return;
      value = value.copyWith(lock: lock);
      _scheduleHeartbeat(lock);
    } on LockedException catch (e) {
      if (_disposed) return;
      _forceReadOnly(
        e.lock,
        'Editing taken over by ${e.lock.holder}. You are now read-only.',
      );
    } on NotFoundException {
      if (_disposed) return;
      _forceReadOnly(null, 'Lock expired. Re-acquire to continue editing.');
    } on ApiException {
      // Transient — let the next heartbeat retry by rescheduling.
      _scheduleHeartbeat(value.lock ?? Lock(holder: _actor, expiresAt: _now()));
    }
  }

  void _stopHeartbeat() {
    _heartbeatGen += 1;
  }

  void _forceReadOnly(Lock? lock, String banner) {
    _stopHeartbeat();
    value = value.copyWith(
      mode: NoteMode.viewing,
      lock: lock,
      editTitle: null,
      editContent: null,
      conflictCurrent: null,
      lockedByOtherBanner: banner,
    );
  }

  void _onEvent(RealtimeEvent event) {
    if (event is! RealtimeMessage) return;
    final msg = event.message;
    if (msg is PresenceEvent) {
      if (msg.noteId != _noteId) return;
      value = value.copyWith(viewers: List<String>.unmodifiable(msg.viewers));
    } else if (msg is LockEvent) {
      if (msg.noteId != _noteId) return;
      _lockGen += 1;
      final newLock = (msg.holder == null || msg.expiresAt == null)
          ? null
          : Lock(holder: msg.holder!, expiresAt: msg.expiresAt!);
      // Mid-edit, if the holder switched away from us, drop into read-only.
      if (value.mode == NoteMode.editing &&
          newLock != null &&
          newLock.holder != _actor) {
        _forceReadOnly(
          newLock,
          'Editing taken over by ${newLock.holder}. You are now read-only.',
        );
        return;
      }
      value = value.copyWith(lock: newLock);
    } else if (msg is ChangedEvent) {
      if (msg.noteId != _noteId) return;
      // Don't disturb the user mid-edit; the next save will surface a 409
      // if they're working on a stale version.
      if (value.mode == NoteMode.editing ||
          value.mode == NoteMode.saving ||
          value.mode == NoteMode.conflict) {
        return;
      }
      // Refresh the read-only view in the background.
      unawaited(_refreshNoteFromServer());
    }
  }

  Future<void> _refreshNoteFromServer() async {
    final gen = ++_noteFetchGen;
    final lockGen = _lockGen;
    try {
      final note = await _api.getNote(_noteId);
      if (!_canCommitNoteFetch(gen)) return;
      _commitFetchedNote(note, lockGen: lockGen);
    } on ApiException {
      // Ignore — next user action will retry.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopHeartbeat();
    _sub?.cancel();
    _onUnsubscribe?.call(_noteId);
    super.dispose();
  }

  /// Sends `DELETE /notes/{id}`. While editing, leaves edit mode first so the
  /// lock is released before the note disappears. A 404 counts as success:
  /// the note is gone either way. Any other error returns to viewing with
  /// [NoteState.error] set.
  Future<void> delete() async {
    if (_disposed) return;
    switch (value.mode) {
      case NoteMode.editing || NoteMode.conflict:
        await exitEditing();
        if (_disposed) return;
      case NoteMode.viewing:
        break;
      default:
        return;
    }
    value = value.copyWith(mode: NoteMode.deleting, error: null);
    try {
      await _api.deleteNote(_noteId);
    } on NotFoundException {
      // Already gone; fall through to the deleted state.
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.viewing, error: e);
      return;
    }
    if (_disposed) return;
    value = value.copyWith(mode: NoteMode.deleted);
  }

  /// Moves the note to [path] via `PUT /notes/{id}` (title/content unchanged,
  /// `If-Match` from the last-loaded version). Only valid while viewing —
  /// callers offer the move action from the read-only view, same as delete.
  ///
  /// `409 path_conflict` and `423 locked` are left on [NoteState.error] for
  /// the view to surface (see the existing save-conflict/lock-banner UX
  /// this reuses) rather than handled here; the note stays open and, for a
  /// path conflict, unmoved. A `423` also updates [NoteState.lock] so the
  /// view's existing "`<holder>` is editing this note" banner picks it up.
  Future<void> move(String path) async {
    if (_disposed) return;
    if (value.mode != NoteMode.viewing) return;
    final note = value.note;
    if (note == null) return;
    value = value.copyWith(mode: NoteMode.moving, error: null);
    try {
      final updated = await _api.updateNote(
        id: _noteId,
        title: note.title,
        content: note.content,
        ifMatch: note.version,
        path: path,
      );
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.viewing, note: updated);
    } on LockedException catch (e) {
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.viewing, lock: e.lock, error: e);
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.viewing, error: e);
    }
  }
}
