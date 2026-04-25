import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:shared/shared.dart';

/// Routes server-emitted [LockEvent]s and [ChangedEvent]s to every WebSocket
/// connection that has subscribed to the corresponding note (or wildcard).
///
/// The broadcaster is a pure routing layer: it does not own connection
/// lifecycle (handshake, ping, presence) — that lives in the WS route. Each
/// registered connection gets a single-subscriber [Stream] of [WsMessage]s
/// it can drain into its own outbox.
class Broadcaster {
  /// Creates a broadcaster. [logger] is optional and used for diagnostics
  /// when a slow consumer must be evicted by the WS layer.
  Broadcaster({Logger? logger}) : _log = logger ?? Logger('broadcaster');

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
    final sub = _Subscriber(connectionId);
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

  /// Sends [event] to every registered subscriber that matches.
  void _emit(String noteId, WsMessage event) {
    if (_subs.isEmpty) return;
    for (final sub in _subs.values) {
      if (sub.wildcard || sub.notes.contains(noteId)) {
        sub.send(event);
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
  _Subscriber(this.id);

  final String id;
  final StreamController<WsMessage> _outbox = StreamController<WsMessage>();
  final Set<String> notes = HashSet<String>();
  bool wildcard = false;

  Stream<WsMessage> get stream => _outbox.stream;

  void send(WsMessage event) {
    if (_outbox.isClosed) return;
    _outbox.add(event);
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
