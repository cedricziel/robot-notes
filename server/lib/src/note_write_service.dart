import 'dart:async';

import 'package:flutter_otel_api/flutter_otel_api.dart' hide Logger;
import 'package:logging/logging.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/links.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';

/// Orchestrates the side-effects of every successful note write:
/// 1. Canonical filesystem write via [Storage].
/// 2. FTS5 cache update via [SearchIndex].
/// 3. In-memory listing index update via [MetaIndex].
/// 4. Outgoing-link index update via [LinkIndex].
/// 5. Fan-out to subscribed WebSocket clients via [Broadcaster].
/// 6. When a write changes a note's title: rename propagation — rewriting
///    `[[OldTitle]]` / `[[OldTitle|Alias]]` to the new title in every other
///    note that links to it (see `links` spec).
///
/// Order matters: [Storage] is the source of truth, so it goes first.
/// The derived indices (search, meta, links) are updated next while the
/// request is still in flight — this guarantees that when the response
/// reaches the client, a follow-up `GET /search`, `GET /notes`, or
/// `GET /notes/{id}/links` reflects the change. The broadcast is
/// best-effort: if [Broadcaster.emitChanged] throws, we log and continue
/// rather than rolling back the file write, because the file IS the
/// canonical state and the WS layer is purely advisory.
class NoteWriteService {
  /// Wires the service to its collaborators. [logger] is optional;
  /// production callers can pass a named logger so broadcast failures
  /// and rename-propagation warnings surface in a recognisable channel.
  /// [tracer] is optional; production callers pass the server's tracer so
  /// each write gets a `note.write.<verb>` span naming the note.
  ///
  /// [linkIndex] and [lockManager] default to fresh, empty instances
  /// when omitted — safe for callers that don't exercise links or locks
  /// (most existing tests), but production wiring (`app_deps.dart`)
  /// MUST pass the same shared instances used elsewhere, or rename
  /// propagation and its lock checks would operate on a disconnected
  /// copy of the real state.
  NoteWriteService({
    required this.storage,
    required this.metaIndex,
    required this.searchIndex,
    required this.broadcaster,
    LinkIndex? linkIndex,
    LockManager? lockManager,
    Logger? logger,
    Tracer? tracer,
  })  : linkIndex = linkIndex ?? LinkIndex(),
        lockManager = lockManager ?? LockManager(),
        _log = logger ?? Logger('note_write'),
        _tracer = tracer ?? const NoopTracer('note_write');

  /// Canonical filesystem-backed note store.
  final Storage storage;

  /// In-memory listing index, kept in sync with [storage].
  final MetaIndex metaIndex;

  /// FTS5 search index, kept in sync with [storage].
  final SearchIndex searchIndex;

  /// WebSocket fan-out layer.
  final Broadcaster broadcaster;

  /// Outgoing-link index, kept in sync with [storage]; also the source of
  /// rename-propagation candidates (see [_propagateRename]).
  final LinkIndex linkIndex;

  /// Soft editor lock manager, consulted before each rename-propagation
  /// rewrite so a note locked by someone else is skipped rather than
  /// forced (see `lock-management` spec).
  final LockManager lockManager;

  final Logger _log;
  final Tracer _tracer;

  /// Persists a new note and updates every derived view.
  ///
  /// Returns the freshly stored note. The caller's response payload is
  /// derived from this value, so the broadcast event the WS layer emits
  /// always carries the same `version` the HTTP response advertises.
  Future<StoredNote> create({
    required String title,
    required String content,
    required String actor,
    String path = '',
  }) {
    return _tracer.startActiveSpan('note.write.create', (span) async {
      final note = await storage.create(
        title: title,
        content: content,
        path: path,
      );
      span.setAttribute('note.id', note.id);
      final summary = note.toSummary();
      // metaIndex is upserted before the search index reads from it below,
      // so link resolution (including a self-referential link) sees this
      // note.
      metaIndex.upsert(summary);
      linkIndex.upsert(note.id, note.content);
      searchIndex.upsert(
        id: note.id,
        title: note.title,
        path: note.path,
        content: note.content,
        updatedAt: note.updatedAt,
        tags: summary.tags,
        links: _searchLinkEdges(note.id),
      );
      _safeBroadcast(
        ChangedEvent(
          noteId: note.id,
          version: note.version,
          by: actor,
          action: ChangeAction.created,
        ),
      );
      _log.info('note ${note.id} created by $actor');
      return note;
    });
  }

  /// Updates an existing note (subject to [ifMatch] optimistic concurrency)
  /// and propagates the change to the search/meta/link indices and WS
  /// subscribers. When [title] differs from the note's prior title, also
  /// rewrites every other note's `[[OldTitle]]` links to the new title
  /// (see [_propagateRename]) before returning.
  Future<StoredNote> update({
    required String id,
    required String title,
    required String content,
    required int ifMatch,
    required String actor,
    String? path,
  }) {
    return _tracer.startActiveSpan(
      'note.write.update',
      attributes: {'note.id': id},
      (span) async {
        final before = await storage.read(id);
        final updated = await storage.update(
          id: id,
          title: title,
          content: content,
          ifMatch: ifMatch,
          path: path,
        );
        final summary = updated.toSummary();
        metaIndex.upsert(summary);
        linkIndex.upsert(updated.id, updated.content);
        searchIndex.upsert(
          id: updated.id,
          title: updated.title,
          path: updated.path,
          content: updated.content,
          updatedAt: updated.updatedAt,
          tags: summary.tags,
          links: _searchLinkEdges(updated.id),
        );
        // A path change broadcasts as `moved` rather than `updated` (per
        // notes-api), even if title/content changed in the same request —
        // "moved" is what tells subscribed clients their folder tree view
        // needs a re-fetch, which a plain `updated` wouldn't trigger.
        final action = updated.path != before.path
            ? ChangeAction.moved
            : ChangeAction.updated;
        _safeBroadcast(
          ChangedEvent(
            noteId: updated.id,
            version: updated.version,
            by: actor,
            action: action,
          ),
        );
        _log.info(
          'note ${updated.id} ${action.name} by $actor '
          '(version ${updated.version})',
        );
        if (before.title != updated.title) {
          await _propagateRename(
            oldTitle: before.title,
            newTitle: updated.title,
            renamedId: updated.id,
            actor: actor,
          );
        }
        return updated;
      },
    );
  }

  /// Finds every other note with a *parsed* outgoing link (not a raw text
  /// search) whose target title equals [oldTitle], and rewrites it to
  /// target [newTitle] instead, preserving any alias. Each rewrite goes
  /// through [update] itself so it gets the same version bump, search/meta
  /// re-indexing, and broadcast that any other write gets — attributed to
  /// [actor] (the actor who performed the rename), not the referencing
  /// note's own last editor.
  ///
  /// A referencing note currently locked by an actor other than [actor] is
  /// skipped (never forced) and logged as a warning naming the note id and
  /// lock holder, per `lock-management`'s rename-propagation requirement.
  Future<void> _propagateRename({
    required String oldTitle,
    required String newTitle,
    required String renamedId,
    required String actor,
  }) async {
    final candidates = linkIndex
        .sourcesLinkingToTitle(oldTitle)
        .where((sourceId) => sourceId != renamedId)
        .toList();
    for (final sourceId in candidates) {
      final lock = lockManager.lockOf(sourceId);
      if (lock != null && lock.holder != actor) {
        _log.warning(
          'Skipping rename-propagation rewrite of note $sourceId: '
          'locked by ${lock.holder}',
        );
        continue;
      }
      try {
        final source = await storage.read(sourceId);
        final rewritten = rewriteLinks(
          source.content,
          oldTitle: oldTitle,
          newTitle: newTitle,
        );
        if (rewritten == source.content) continue;
        await update(
          id: sourceId,
          title: source.title,
          content: rewritten,
          ifMatch: source.version,
          actor: actor,
          path: source.path,
        );
      } on NoteNotFoundException {
        // Raced with a concurrent delete of the referencing note; nothing
        // to rewrite.
      } on VersionConflictException {
        _log.warning(
          'Skipping rename-propagation rewrite of note $sourceId: '
          'it changed concurrently',
        );
      }
    }
  }

  /// Deletes a note and removes it from every derived view. Returns the
  /// pre-delete record (so the caller can include the final version in
  /// the broadcast event without re-reading the file).
  Future<StoredNote> delete({
    required String id,
    required String actor,
  }) {
    return _tracer.startActiveSpan(
      'note.write.delete',
      attributes: {'note.id': id},
      (span) async {
        final existing = await storage.read(id);
        await storage.delete(id);
        searchIndex.delete(id);
        metaIndex.remove(id);
        linkIndex.remove(id);
        _safeBroadcast(
          ChangedEvent(
            noteId: id,
            version: existing.version,
            by: actor,
            action: ChangeAction.deleted,
          ),
        );
        _log.info('note $id deleted by $actor');
        return existing;
      },
    );
  }

  /// Builds the [SearchLinkEdge] list [SearchIndex.upsert] needs from
  /// [id]'s freshly-parsed [linkIndex] entry, resolving each target title
  /// against [metaIndex]'s live state — the same resolution
  /// [MetaIndex.resolveTitle] uses everywhere else, so a link that
  /// resolves for `GET /notes/{id}/links` resolves here too.
  List<SearchLinkEdge> _searchLinkEdges(NoteId id) => [
        for (final edge in linkIndex.outgoing(id))
          SearchLinkEdge(
            targetTitle: edge.targetTitle,
            targetId: metaIndex.resolveTitle(edge.targetTitle),
          ),
      ];

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
