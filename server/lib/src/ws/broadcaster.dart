import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:shared/shared.dart';

/// Default ceiling on the per-subscriber outbox. When the queued depth
/// exceeds this many events the broadcaster treats the consumer as slow,
/// closes its stream, and removes it.
const int kDefaultSlowConsumerThreshold = 1024;

/// Routes server-emitted [LockEvent]s and [ChangedEvent]s to every WebSocket
/// connection that has subscribed to the corresponding note (or wildcard).
///
/// The broadcaster is a pure routing layer: it does not own connection
/// lifecycle (handshake, ping, presence) — that lives in the WS route. Each
/// registered connection gets a single-subscriber [Stream] of [WsMessage]s
/// it can drain into its own outbox.
///
/// Slow consumers (whose outbox depth exceeds the configured threshold)
/// are dropped: their stream is closed and they are removed from the
/// routing table so the broadcast loop never blocks waiting on a single
/// client.
class Broadcaster {
  /// Creates a broadcaster. [slowConsumerThreshold] caps the per-subscriber
  /// pending-event count before the connection is evicted; [logger] is
  /// optional and used for diagnostics.
  Broadcaster({
    int slowConsumerThreshold = kDefaultSlowConsumerThreshold,
    Logger? logger,
  })  : _slowConsumerThreshold = slowConsumerThreshold,
        _log = logger ?? Logger('broadcaster');

  final int _slowConsumerThreshold;
  final Logger _log;
  final Map<String, _Subscriber> _subs = HashMap<String, _Subscriber>();

  /// Returns the number of currently registered connections (test hook).
  int get connectionCount => _subs.length;

  /// True when [connectionId] is registered.
  bool isRegistered(String connectionId) => _subs.containsKey(connectionId);

  /// Registers [connectionId] and returns the per-connection event stream.
  /// The stream completes when [disconnect] (or [close]) is invoked.
  ///
  /// Throws [StateError] if [connectionId] is already registered.
  Stream<WsMessage> register(String connectionId) {
    if (_subs.containsKey(connectionId)) {
      throw StateError('connection already registered: $connectionId');
    }
    final sub = _Subscriber(connectionId, _slowConsumerThreshold);
    _subs[connectionId] = sub;
    return sub.stream;
  }

  /// Subscribes [connectionId] to events for [noteId]. Idempotent. Calls on
  /// unregistered connections are silently ignored.
  void subscribe(String connectionId, String noteId) {
    _subs[connectionId]?.notes.add(noteId);
  }

  /// Subscribes [connectionId] to events for ALL notes. Idempotent.
  void subscribeWildcard(String connectionId) {
    final sub = _subs[connectionId];
    if (sub == null) return;
    sub.wildcard = true;
  }

  /// Removes a per-note subscription. Idempotent. Wildcard is unaffected.
  void unsubscribe(String connectionId, String noteId) {
    _subs[connectionId]?.notes.remove(noteId);
  }

  /// Drops [connectionId] entirely; closes its outbound stream so the WS
  /// layer can finish its `onDone` handling.
  Future<void> disconnect(String connectionId) async {
    final sub = _subs.remove(connectionId);
    if (sub == null) return;
    await sub.close();
  }

  /// Emits a lock-state transition. Routed to every subscriber whose
  /// `notes` set contains the event's `noteId`, plus all wildcard subscribers.
  void emitLock(LockEvent event) => _emit(event.noteId, event);

  /// Emits a changed-note notification. Routed identically to [emitLock].
  void emitChanged(ChangedEvent event) => _emit(event.noteId, event);

  /// Emits a presence-roster update for a note. Routed identically to
  /// [emitLock]; the WS route uses this to fan out viewer-set changes
  /// produced by the presence tracker.
  void emitPresence(PresenceEvent event) => _emit(event.noteId, event);

  /// Sends [event] to every registered subscriber that matches.
  void _emit(String noteId, WsMessage event) {
    if (_subs.isEmpty) return;
    List<String>? toDrop;
    for (final sub in _subs.values) {
      if (sub.wildcard || sub.notes.contains(noteId)) {
        if (sub.send(event)) {
          (toDrop ??= []).add(sub.id);
        }
      }
    }
    if (toDrop != null) {
      for (final id in toDrop) {
        _log.warning('dropping slow consumer $id');
        unawaited(disconnect(id));
      }
    }
  }

  /// Closes every registered connection's stream. Intended for shutdown.
  Future<void> close() async {
    final ids = List<String>.from(_subs.keys);
    for (final id in ids) {
      await disconnect(id);
    }
    _log.fine('broadcaster closed');
  }
}

class _Subscriber {
  _Subscriber(this.id, this._slowConsumerThreshold);

  final String id;
  final int _slowConsumerThreshold;
  final StreamController<WsMessage> _outbox = StreamController<WsMessage>();
  final Set<String> notes = HashSet<String>();
  bool wildcard = false;
  int _pending = 0;
  bool _dropped = false;

  /// The downstream stream wraps the controller so we can decrement pending
  /// every time the consumer pulls an event. The wrapper is single-use,
  /// matching the underlying non-broadcast controller.
  Stream<WsMessage> get stream => _outbox.stream.map((event) {
        if (_pending > 0) _pending--;
        return event;
      });

  /// Returns true if the broadcaster should drop this subscriber after
  /// [send]: the outbox grew beyond the slow-consumer threshold without
  /// being drained.
  bool send(WsMessage event) {
    if (_dropped || _outbox.isClosed) return false;
    if (_pending >= _slowConsumerThreshold) {
      _dropped = true;
      return true;
    }
    _pending++;
    _outbox.add(event);
    return false;
  }

  Future<void> close() async {
    if (_outbox.isClosed) return;
    // Closing a non-broadcast StreamController whose stream has never been
    // listened to does not complete its returned future until a listener
    // subscribes. We want disconnect/close to be promptly awaitable in tests
    // that register and never listen, so detach the close in that case.
    if (_outbox.hasListener) {
      await _outbox.close();
    } else {
      unawaited(_outbox.close());
    }
  }
}
