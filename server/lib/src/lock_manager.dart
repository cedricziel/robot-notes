import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/clock.dart';
import 'package:shared/shared.dart';

/// Default soft-editor lock TTL. The notes API allows operators to override
/// this via `--lock-ttl-seconds`; this value is what tests and the
/// in-process default fall back to.
const Duration kDefaultLockTtl = Duration(seconds: 60);

/// Thrown by [LockManager.acquire] / [LockManager.heartbeat] /
/// [LockManager.release] when the requested action is incompatible with the
/// current lock holder. The HTTP layer maps this to `423 Locked`.
@immutable
class LockedException implements Exception {
  /// Creates a contention error carrying the [current] live lock so the API
  /// layer can surface holder + expiry to the client.
  const LockedException({required this.current, required this.actor});

  /// The live lock that is blocking the caller.
  final Lock current;

  /// Actor who attempted (and was rejected from) the operation.
  final String actor;

  @override
  String toString() =>
      'LockedException: $actor blocked by holder ${current.holder}';
}

/// Thrown by [LockManager.heartbeat] when there is no live lock to extend.
/// The HTTP layer maps this to `404 Not Found` with code `lock_not_found`.
@immutable
class LockNotFoundException implements Exception {
  /// Creates a not-found exception for [noteId].
  const LockNotFoundException(this.noteId);

  /// The note that has no live lock.
  final String noteId;

  @override
  String toString() => 'LockNotFoundException: $noteId';
}

/// In-memory soft editor lock manager.
///
/// Locks are entirely process-local: a server restart wipes them. Each lock
/// carries a holder (the actor identity from the request) and an `expiresAt`
/// instant; expired locks are treated as released the next time anyone
/// inspects the slot. State transitions emit [LockEvent]s on
/// [transitions] for the WebSocket broadcaster to forward.
class LockManager {
  /// Creates a manager with the given [clock] and [ttl].
  LockManager({
    Clock clock = const Clock(),
    Duration ttl = kDefaultLockTtl,
    Logger? logger,
  })  : _clock = clock,
        _ttl = ttl,
        _log = logger ?? Logger('lock_manager');

  final Clock _clock;
  final Duration _ttl;
  final Logger _log;
  final Map<String, Lock> _locks = {};
  final StreamController<LockEvent> _events =
      StreamController<LockEvent>.broadcast();

  /// Stream of lock state transitions (acquire / extend / release / expiry).
  /// The broadcaster fans these out to subscribed WS connections.
  Stream<LockEvent> get transitions => _events.stream;

  /// Returns the live lock for [noteId], or `null` if none exists or the
  /// previously-held lock has expired. Calling [lockOf] for an expired lock
  /// emits a release [LockEvent] before returning `null`.
  Lock? lockOf(String noteId) => _evict(noteId);

  /// Acquires the lock for [noteId] on behalf of [actor]. Idempotent for
  /// the current holder: re-acquiring extends the TTL and emits a fresh
  /// transition. Throws [LockedException] when a different live holder is
  /// in possession.
  Future<Lock> acquire({required String noteId, required String actor}) async {
    final live = _evict(noteId);
    if (live != null && live.holder != actor) {
      throw LockedException(current: live, actor: actor);
    }
    final next = Lock(holder: actor, expiresAt: _clock.nowUtc().add(_ttl));
    _locks[noteId] = next;
    _log.fine('lock acquire $noteId by $actor until ${next.expiresAt}');
    _emit(noteId, holder: next.holder, expiresAt: next.expiresAt);
    return next;
  }

  /// Heartbeats an existing lock for [noteId] held by [actor], extending
  /// its expiry by the manager's TTL. Throws [LockedException] if the lock
  /// is held by someone else, or [LockNotFoundException] if no live lock
  /// exists (including the case where the previous lock just expired).
  Future<Lock> heartbeat({
    required String noteId,
    required String actor,
  }) async {
    final live = _evict(noteId);
    if (live == null) throw LockNotFoundException(noteId);
    if (live.holder != actor) {
      throw LockedException(current: live, actor: actor);
    }
    final next = Lock(holder: actor, expiresAt: _clock.nowUtc().add(_ttl));
    _locks[noteId] = next;
    _log.fine('lock heartbeat $noteId by $actor until ${next.expiresAt}');
    _emit(noteId, holder: next.holder, expiresAt: next.expiresAt);
    return next;
  }

  /// Releases the lock for [noteId] on behalf of [actor]. Idempotent when
  /// no live lock exists (already-released or expired). Throws
  /// [LockedException] when a different actor still holds a live lock.
  Future<void> release({
    required String noteId,
    required String actor,
  }) async {
    final live = _evict(noteId);
    if (live == null) {
      // Already released (or expired and evicted) — no-op, no event.
      return;
    }
    if (live.holder != actor) {
      throw LockedException(current: live, actor: actor);
    }
    _locks.remove(noteId);
    _log.fine('lock release $noteId by $actor');
    _emit(noteId);
  }

  /// Releases all in-memory state. Tests use this to tear down between
  /// scenarios; production callers SHALL NOT invoke it during normal
  /// operation.
  Future<void> close() async {
    _locks.clear();
    await _events.close();
  }

  /// Returns the currently-held lock for [noteId] if it has not expired,
  /// otherwise removes the stale entry, emits a release transition, and
  /// returns `null`. All public methods funnel through here so expiry is
  /// handled identically across call sites.
  Lock? _evict(String noteId) {
    final lock = _locks[noteId];
    if (lock == null) return null;
    if (!lock.expiresAt.isAfter(_clock.nowUtc())) {
      _locks.remove(noteId);
      _log.fine('lock expired $noteId (was held by ${lock.holder})');
      _emit(noteId);
      return null;
    }
    return lock;
  }

  void _emit(String noteId, {String? holder, DateTime? expiresAt}) {
    if (_events.isClosed) return;
    _events.add(
      LockEvent(noteId: noteId, holder: holder, expiresAt: expiresAt),
    );
  }
}
