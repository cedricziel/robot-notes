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
  })  : _api = api,
        _noteId = noteId,
        _actor = actor,
        _onSubscribe = onSubscribe,
        _onUnsubscribe = onUnsubscribe,
        _now = clock ?? DateTime.now,
        _heartbeatInterval = heartbeatInterval ?? _defaultHeartbeatInterval,
        _scheduler = scheduler ?? Future<void>.delayed,
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

  final RobotNotesClient _api;
  final String _noteId;
  final String _actor;
  final void Function(String)? _onSubscribe;
  final void Function(String)? _onUnsubscribe;
  final DateTime Function() _now;
  final Duration Function(Lock, DateTime) _heartbeatInterval;
  final Future<void> Function(Duration) _scheduler;

  StreamSubscription<RealtimeEvent>? _sub;
  bool _disposed = false;
  int _heartbeatGen = 0;

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
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(error: e);
    }
  }

  /// Asks the server for the editor lock. On success transitions to
  /// [NoteMode.editing] and schedules the heartbeat loop. On 423 surfaces
  /// the holder via [NoteState.lock] but stays read-only.
  Future<void> enterEditMode() async {
    if (_disposed) return;
    if (value.mode != NoteMode.viewing) return;
    final note = value.note;
    if (note == null) return;
    value = value.copyWith(mode: NoteMode.acquiringLock, error: null);
    try {
      final lock = await _api.acquireLock(_noteId);
      if (_disposed) return;
      value = value.copyWith(
        mode: NoteMode.editing,
        lock: lock,
        editTitle: note.title,
        editContent: note.content,
        lockedByOtherBanner: null,
      );
      _scheduleHeartbeat(lock);
    } on LockedException catch (e) {
      if (_disposed) return;
      value = value.copyWith(
        mode: NoteMode.viewing,
        lock: e.lock,
        error: e,
      );
    } on ApiException catch (e) {
      if (_disposed) return;
      value = value.copyWith(mode: NoteMode.viewing, error: e);
    }
  }

  void setEditTitle(String title) {
    if (value.mode != NoteMode.editing && value.mode != NoteMode.conflict) {
      return;
    }
    value = value.copyWith(editTitle: title);
  }

  void setEditContent(String content) {
    if (value.mode != NoteMode.editing && value.mode != NoteMode.conflict) {
      return;
    }
    value = value.copyWith(editContent: content);
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
    try {
      await _api.releaseLock(_noteId);
    } on ApiException {
      // Best-effort release.
    }
    if (_disposed) return;
    value = value.copyWith(
      mode: NoteMode.viewing,
      lock: null,
      editTitle: null,
      editContent: null,
      conflictCurrent: null,
    );
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
    try {
      final note = await _api.getNote(_noteId);
      if (_disposed) return;
      if (value.mode != NoteMode.viewing) return;
      value = value.copyWith(note: note, lock: note.lock);
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
}
