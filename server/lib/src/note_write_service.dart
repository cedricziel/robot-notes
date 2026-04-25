import 'dart:async';

import 'package:logging/logging.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';

/// Orchestrates the four side-effects of every successful note write:
/// 1. Canonical filesystem write via [Storage].
/// 2. FTS5 cache update via [SearchIndex].
/// 3. In-memory listing index update via [MetaIndex].
/// 4. Fan-out to subscribed WebSocket clients via [Broadcaster].
///
/// Order matters: [Storage] is the source of truth, so it goes first.
/// The two derived indices (search + meta) are updated next while the
/// request is still in flight — this guarantees that when the response
/// reaches the client, a follow-up `GET /search` or `GET /notes` reflects
/// the change. The broadcast is best-effort: if [Broadcaster.emitChanged]
/// throws, we log and continue rather than rolling back the file write,
/// because the file IS the canonical state and the WS layer is purely
/// advisory.
class NoteWriteService {
  /// Wires the service to its four collaborators. [logger] is optional;
  /// production callers can pass a named logger so broadcast failures
  /// surface in a recognisable channel.
  NoteWriteService({
    required this.storage,
    required this.metaIndex,
    required this.searchIndex,
    required this.broadcaster,
    Logger? logger,
  }) : _log = logger ?? Logger('note_write');

  /// Canonical filesystem-backed note store.
  final Storage storage;

  /// In-memory listing index, kept in sync with [storage].
  final MetaIndex metaIndex;

  /// FTS5 search index, kept in sync with [storage].
  final SearchIndex searchIndex;

  /// WebSocket fan-out layer.
  final Broadcaster broadcaster;

  final Logger _log;

  /// Persists a new note and updates every derived view.
  ///
  /// Returns the freshly stored note. The caller's response payload is
  /// derived from this value, so the broadcast event the WS layer emits
  /// always carries the same `version` the HTTP response advertises.
  Future<StoredNote> create({
    required String title,
    required String content,
    required String actor,
  }) async {
    final note = await storage.create(title: title, content: content);
    searchIndex.upsert(
      id: note.id,
      title: note.title,
      content: note.content,
    );
    metaIndex.upsert(note.toSummary());
    _safeBroadcast(
      ChangedEvent(
        noteId: note.id,
        version: note.version,
        by: actor,
        action: ChangeAction.created,
      ),
    );
    return note;
  }

  /// Updates an existing note (subject to [ifMatch] optimistic concurrency)
  /// and propagates the change to the search/meta indices and WS subscribers.
  Future<StoredNote> update({
    required String id,
    required String title,
    required String content,
    required int ifMatch,
    required String actor,
  }) async {
    final updated = await storage.update(
      id: id,
      title: title,
      content: content,
      ifMatch: ifMatch,
    );
    searchIndex.upsert(
      id: updated.id,
      title: updated.title,
      content: updated.content,
    );
    metaIndex.upsert(updated.toSummary());
    _safeBroadcast(
      ChangedEvent(
        noteId: updated.id,
        version: updated.version,
        by: actor,
        action: ChangeAction.updated,
      ),
    );
    return updated;
  }

  /// Deletes a note and removes it from every derived view. Returns the
  /// pre-delete record (so the caller can include the final version in
  /// the broadcast event without re-reading the file).
  Future<StoredNote> delete({
    required String id,
    required String actor,
  }) async {
    final existing = await storage.read(id);
    await storage.delete(id);
    searchIndex.delete(id);
    metaIndex.remove(id);
    _safeBroadcast(
      ChangedEvent(
        noteId: id,
        version: existing.version,
        by: actor,
        action: ChangeAction.deleted,
      ),
    );
    return existing;
  }

  void _safeBroadcast(ChangedEvent event) {
    try {
      broadcaster.emitChanged(event);
    } on Object catch (e, st) {
      _log.warning(
        'Failed to broadcast changed event for ${event.noteId}',
        e,
        st,
      );
    }
  }
}
