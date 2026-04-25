import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:shared/shared.dart';

/// Tracks which actors are currently viewing each note via per-note
/// WebSocket subscriptions. Exposes a synchronous mutation API: each
/// state-changing call returns the [PresenceEvent] that the caller (the WS
/// route) should fan out, or `null` when the deduped viewer set for the
/// note did not actually change.
///
/// "Actor" is the display identity bound at WS auth time. Two connections
/// from the same actor on the same note collapse to a single viewer entry,
/// and removing one of them does not emit an event until the last
/// connection for that actor disappears.
class PresenceTracker {
  /// Creates a tracker. [logger] is optional and used only for diagnostics.
  PresenceTracker({Logger? logger}) : _log = logger ?? Logger('presence');

  final Logger _log;

  // noteId -> connectionId -> actor
  final Map<String, Map<String, String>> _byNote =
      HashMap<String, Map<String, String>>();

  // connectionId -> set of noteIds (so disconnect can find them in O(notes))
  final Map<String, Set<String>> _byConnection = HashMap<String, Set<String>>();

  /// Number of notes that currently have at least one viewer.
  int get watchedNoteCount => _byNote.length;

  /// Returns the alphabetically-sorted list of unique viewer names for
  /// [noteId]. The empty list is returned when no one is viewing the note.
  List<String> viewersOf(String noteId) {
    final conns = _byNote[noteId];
    if (conns == null || conns.isEmpty) return const <String>[];
    final actors = conns.values.toSet().toList()..sort();
    return actors;
  }

  /// Registers [connectionId] (identified by [actor]) as a viewer of
  /// [noteId]. Returns a [PresenceEvent] if the deduped viewer set
  /// changed, else `null` (the actor was already present via another
  /// connection, or the connection was already viewing this note).
  PresenceEvent? add(String connectionId, String actor, String noteId) {
    final conns = _byNote.putIfAbsent(noteId, HashMap<String, String>.new);
    final before = conns.values.toSet();
    if (conns[connectionId] == actor) return null;
    conns[connectionId] = actor;
    _byConnection.putIfAbsent(connectionId, HashSet<String>.new).add(noteId);

    final after = conns.values.toSet();
    if (_setsEqual(before, after)) return null;
    _log.fine('presence add $actor on $noteId via $connectionId');
    return PresenceEvent(noteId: noteId, viewers: viewersOf(noteId));
  }

  /// Removes [connectionId] from [noteId]'s viewer set. Returns a
  /// [PresenceEvent] if the deduped viewer set changed, else `null`.
  PresenceEvent? remove(String connectionId, String noteId) {
    final conns = _byNote[noteId];
    if (conns == null) return null;
    final removed = conns.remove(connectionId);
    if (removed == null) return null;
    if (conns.isEmpty) _byNote.remove(noteId);
    _byConnection[connectionId]?.remove(noteId);
    if (_byConnection[connectionId]?.isEmpty ?? false) {
      _byConnection.remove(connectionId);
    }

    final stillPresent = conns.values.contains(removed);
    if (stillPresent) return null;
    _log.fine('presence remove $removed from $noteId via $connectionId');
    return PresenceEvent(noteId: noteId, viewers: viewersOf(noteId));
  }

  /// Removes [connectionId] from every note it was viewing. Returns a map
  /// of `noteId → PresenceEvent` for every note where the deduped viewer
  /// set actually changed. The map is empty if the connection had no
  /// presence to clean up, or if every removal was a duplicate.
  Map<String, PresenceEvent> disconnect(String connectionId) {
    final notes = _byConnection.remove(connectionId);
    if (notes == null || notes.isEmpty) return const {};
    final events = <String, PresenceEvent>{};
    for (final noteId in notes) {
      final conns = _byNote[noteId];
      if (conns == null) continue;
      final removed = conns.remove(connectionId);
      if (conns.isEmpty) _byNote.remove(noteId);
      if (removed == null) continue;
      if (conns.values.contains(removed)) continue;
      events[noteId] = PresenceEvent(
        noteId: noteId,
        viewers: viewersOf(noteId),
      );
    }
    return events;
  }

  static bool _setsEqual(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }
}
