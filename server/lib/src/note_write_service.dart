import 'dart:async';

import 'package:dart_otel_api/dart_otel_api.dart' hide Logger;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/databases/definition.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/databases/validation.dart';
import 'package:server/src/embeddings/embedding_provider.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/links.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/tags.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:shared/shared.dart';

/// Thrown by [NoteWriteService.create]/[update]/[patchProperties]/
/// [createRow] when caller-supplied property values fail
/// [validateProperties]. Never thrown for rename propagation or any other
/// internal rewrite — see the `add-databases` design's "Validation ... runs
/// only on caller-supplied values" decision.
@immutable
class PropertyValidationException implements Exception {
  /// Creates a validation exception carrying every [violations] found.
  const PropertyValidationException(this.violations);

  /// Every property violation found; never empty.
  final List<PropertyViolation> violations;

  @override
  String toString() => 'PropertyValidationException: ${violations.join('; ')}';
}

/// Thrown by [NoteWriteService.createDatabase]/[updateDatabase] when the
/// assembled definition fails structural parsing or [validateDefinition].
@immutable
class DefinitionValidationException implements Exception {
  /// Creates a validation exception carrying every [violations] found.
  const DefinitionValidationException(this.violations);

  /// Every definition violation found; never empty.
  final List<DefinitionViolation> violations;

  @override
  String toString() =>
      'DefinitionValidationException: ${violations.join('; ')}';
}

/// Thrown by [NoteWriteService.createRow] when the caller's [path] is
/// outside the target database's folder source.
@immutable
class PathOutsideSourceException implements Exception {
  /// Creates an exception naming the rejected [path] and the source
  /// [folder] it must fall under.
  const PathOutsideSourceException({required this.path, required this.folder});

  /// The rejected path.
  final String path;

  /// The source folder [path] must fall under.
  final String folder;

  @override
  String toString() =>
      'PathOutsideSourceException: "$path" is outside source folder '
      '"$folder"';
}

/// Thrown by [NoteWriteService.createRow]/[updateDatabase] when the named
/// database id has no registered definition.
@immutable
class DatabaseNotFoundException implements Exception {
  /// Creates an exception naming the unresolved database [id].
  const DatabaseNotFoundException(this.id);

  /// The database id that did not resolve.
  final String id;

  @override
  String toString() => 'DatabaseNotFoundException: $id';
}

/// How many times [NoteWriteService.append] re-reads and retries its write
/// after losing a version race before giving up. Shared by the MCP
/// `append_to_note` tool and `POST /notes/{id}/append` so both surfaces
/// have an identical retry budget.
const int kAppendMaxRetries = 3;

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
    this.embeddingProvider,
    this.registry,
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

  /// When configured, `create`/`update` compute an embedding for the
  /// note's content and pass it to [SearchIndex.upsert]. `null` (the
  /// default) means writes behave exactly as before hybrid search existed.
  final EmbeddingProvider? embeddingProvider;

  /// Outgoing-link index, kept in sync with [storage]; also the source of
  /// rename-propagation candidates (see [_propagateRename]).
  final LinkIndex linkIndex;

  /// Soft editor lock manager, consulted before each rename-propagation
  /// rewrite so a note locked by someone else is skipped rather than
  /// forced (see `lock-management` spec).
  final LockManager lockManager;

  /// In-memory database-definition registry, kept current on every write
  /// and delete (see [_refreshRegistry], [delete]). `null` (the default)
  /// means database features are entirely inert: `properties` validation
  /// never runs (nothing covers any note), relation links are never
  /// computed, and [createRow]/[createDatabase]/[updateDatabase] would
  /// have nothing to resolve against — production wiring (`app_deps.dart`)
  /// MUST pass the shared instance.
  final DatabaseRegistry? registry;

  final Logger _log;
  final Tracer _tracer;

  /// Persists a new note and updates every derived view.
  ///
  /// Returns the freshly stored note. The caller's response payload is
  /// derived from this value, so the broadcast event the WS layer emits
  /// always carries the same `version` the HTTP response advertises.
  ///
  /// [properties] is validated against every database whose source covers
  /// `path` (see [DatabaseRegistry.covering]) before anything is written;
  /// a violation throws [PropertyValidationException] and nothing is
  /// persisted. Reserved/server-interpreted keys are rejected by
  /// [validateProperties] itself, so [properties] never ends up carrying
  /// `type`/`tags`/`source`/`properties`/`views`.
  Future<StoredNote> create({
    required String title,
    required String content,
    required String actor,
    String path = '',
    Map<String, Object?>? properties,
  }) {
    return _tracer.startActiveSpan('note.write.create', (span) async {
      if (properties != null && properties.isNotEmpty) {
        _validateCallerProperties(
          path: path,
          tags: computeTags(extra: const {}, content: content),
          isDefinition: false,
          properties: properties,
        );
      }
      final note = await _persistCreate(
        title: title,
        content: content,
        actor: actor,
        path: path,
        extra: properties,
        span: span,
      );
      return note;
    });
  }

  /// Shared storage-write + index-update + broadcast body behind [create],
  /// [createRow], and [createDatabase]. [extra] is passed straight through
  /// to [Storage.create] as-is — validation (or its deliberate absence, for
  /// an internal caller) is the caller's responsibility.
  Future<StoredNote> _persistCreate({
    required String title,
    required String content,
    required String actor,
    required String path,
    required Map<String, Object?>? extra,
    Span? span,
  }) async {
    final note = await storage.create(
      title: title,
      content: content,
      path: path,
      properties: extra,
    );
    span?.setAttribute('note.id', note.id);
    final summary = note.toSummary();
    final embedding = await _embed(
      embeddingInputFor(title: note.title, content: note.content),
    );
    // metaIndex is upserted before the search index reads from it below,
    // so link resolution (including a self-referential link) sees this
    // note.
    metaIndex.upsert(summary);
    final coveringDefs = _coveringOf(note, summary);
    linkIndex.upsert(
      note.id,
      note.content,
      extraLinks: _relationLinks(coveringDefs, note.extra),
    );
    searchIndex.upsert(
      id: note.id,
      title: note.title,
      path: note.path,
      content: note.content,
      updatedAt: note.updatedAt,
      tags: summary.tags,
      links: _searchLinkEdges(note.id),
      embedding: embedding,
      extra: note.extra,
      createdAt: note.createdAt,
      isDefinition: isDatabaseDefinitionExtra(note.extra),
    );
    _refreshRegistry(summary, note.extra);
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
  }

  /// Updates an existing note (subject to [ifMatch] optimistic concurrency)
  /// and propagates the change to the search/meta/link indices and WS
  /// subscribers. When [title] differs from the note's prior title, also
  /// rewrites every other note's `[[OldTitle]]` links to the new title
  /// (see [_propagateRename]) before returning.
  ///
  /// [properties] follows [Storage.update]'s merge rule: omitted (`null`)
  /// leaves every property key untouched, supplied replaces the full set of
  /// property keys (server-interpreted keys are preserved regardless). It
  /// is validated exactly like [create]'s before anything is written; a
  /// violation throws [PropertyValidationException].
  Future<StoredNote> update({
    required String id,
    required String title,
    required String content,
    required int ifMatch,
    required String actor,
    String? path,
    Map<String, Object?>? properties,
  }) {
    return _update(
      id: id,
      title: title,
      content: content,
      ifMatch: ifMatch,
      actor: actor,
      path: path,
      properties: properties,
      validate: true,
    );
  }

  /// Internal counterpart to [update] that never validates [properties] —
  /// used by [_propagateRename] (a rename-driven rewrite of frontmatter
  /// relation values MUST NOT fail because some other, unrelated stored
  /// value happens to be invalid) per the `add-databases` design's
  /// "Validation ... runs only on caller-supplied values" decision.
  Future<StoredNote> updateRaw({
    required String id,
    required String title,
    required String content,
    required int ifMatch,
    required String actor,
    String? path,
    Map<String, Object?>? properties,
  }) {
    return _update(
      id: id,
      title: title,
      content: content,
      ifMatch: ifMatch,
      actor: actor,
      path: path,
      properties: properties,
      validate: false,
    );
  }

  Future<StoredNote> _update({
    required String id,
    required String title,
    required String content,
    required int ifMatch,
    required String actor,
    required String? path,
    required Map<String, Object?>? properties,
    required bool validate,
  }) {
    return _tracer.startActiveSpan(
      'note.write.update',
      attributes: {'note.id': id},
      (span) async {
        final before = await storage.read(id);
        if (validate && properties != null && properties.isNotEmpty) {
          _validateCallerProperties(
            path: path ?? before.path,
            tags: computeTags(extra: before.extra, content: content),
            isDefinition: isDatabaseDefinitionExtra(before.extra),
            properties: properties,
            selfId: id,
          );
        }
        final updated = await storage.update(
          id: id,
          title: title,
          content: content,
          ifMatch: ifMatch,
          path: path,
          properties: properties,
        );
        final summary = updated.toSummary();
        final embedding = await _embed(
          embeddingInputFor(title: updated.title, content: updated.content),
        );
        metaIndex.upsert(summary);
        final coveringDefs = _coveringOf(updated, summary);
        linkIndex.upsert(
          updated.id,
          updated.content,
          extraLinks: _relationLinks(coveringDefs, updated.extra),
        );
        searchIndex.upsert(
          id: updated.id,
          title: updated.title,
          path: updated.path,
          content: updated.content,
          updatedAt: updated.updatedAt,
          tags: summary.tags,
          links: _searchLinkEdges(updated.id),
          embedding: embedding,
          extra: updated.extra,
          createdAt: updated.createdAt,
          isDefinition: isDatabaseDefinitionExtra(updated.extra),
        );
        _refreshRegistry(summary, updated.extra);
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

  /// Appends [text] to the end of note [id] as a safe server-side
  /// read-modify-write: reads the current content, appends on a new line
  /// (unless the note is empty, or already ends with one), and retries
  /// automatically — up to [kAppendMaxRetries] extra attempts — if another
  /// actor's write lands first. The single helper behind both the MCP
  /// `append_to_note` tool and `POST /notes/{id}/append`, so the two
  /// surfaces have byte-identical semantics.
  ///
  /// Checks [lockManager] before the initial read and again before every
  /// retry — another actor may acquire the lock in the gap between a lost
  /// version race and the next attempt — throwing [LockedException] when
  /// [actor] doesn't hold it. Throws [NoteNotFoundException] if the note
  /// doesn't exist, or re-throws the last [VersionConflictException] if
  /// every retry loses the race.
  Future<StoredNote> append({
    required String id,
    required String text,
    required String actor,
  }) {
    return _tracer.startActiveSpan(
      'note.write.append',
      attributes: {'note.id': id},
      (span) async {
        _checkLock(id, actor);
        var current = await storage.read(id);

        for (var attempt = 0; attempt <= kAppendMaxRetries; attempt++) {
          _checkLock(id, actor);
          final needsNewline =
              current.content.isNotEmpty && !current.content.endsWith('\n');
          final nextContent = current.content.isEmpty
              ? text
              : '${current.content}${needsNewline ? '\n' : ''}$text';
          try {
            return await update(
              id: id,
              title: current.title,
              content: nextContent,
              ifMatch: current.version,
              actor: actor,
            );
          } on VersionConflictException catch (e) {
            // The exception carries the fresh state, so retrying needs no
            // extra read.
            current = e.current;
          }
        }
        throw VersionConflictException(
          current: current,
          suppliedIfMatch: current.version,
        );
      },
    );
  }

  /// Throws [LockedException] if [id]'s editor lock is held by an actor
  /// other than [actor].
  void _checkLock(String id, String actor) {
    final active = lockManager.lockOf(id);
    if (active != null && active.holder != actor) {
      throw LockedException(current: active, actor: actor);
    }
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
        final relationDefs = _coveringOf(source, source.toSummary());
        final rewrittenExtra = _rewriteRelationLinks(
          source.extra,
          relationDefs,
          oldTitle: oldTitle,
          newTitle: newTitle,
        );
        final contentChanged = rewritten != source.content;
        final extraChanged = !identical(rewrittenExtra, source.extra);
        if (!contentChanged && !extraChanged) continue;
        await updateRaw(
          id: sourceId,
          title: source.title,
          content: rewritten,
          ifMatch: source.version,
          actor: actor,
          path: source.path,
          properties: extraChanged ? _propertyKeysOnly(rewrittenExtra) : null,
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
        registry?.remove(id);
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

  /// Computes the embedding for [text] (a note's title + content, see
  /// [embeddingInputFor]) via [embeddingProvider], or `null` when
  /// unconfigured, on failure, or when there is nothing to embed — see
  /// [embedOrNull].
  Future<List<double>?> _embed(String text) =>
      embedOrNull(embeddingProvider, text, logger: _log);

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

  // ---------------------------------------------------------------------
  // Property patch (4.5-4.8)
  // ---------------------------------------------------------------------

  /// Sets/unsets frontmatter property keys on note [id] without touching
  /// the body, via [Storage.patchExtra] — see the `add-databases` design's
  /// "Property patch" decision. Needs no `If-Match`: [Storage.patchExtra]
  /// runs inside the same per-note mutex [Storage.update] uses, so a
  /// concurrent `PUT` and this patch serialize with no lost update.
  /// Ignores [lockManager] entirely, per that same decision (an editor
  /// lock protects the body, which a property patch never touches).
  ///
  /// Throws [PropertyValidationException] if [set]/[unset] is empty, a key
  /// appears in both, a key is reserved/server-interpreted/built-in, or a
  /// [set] value fails [validateProperties] — in every case nothing is
  /// written. Broadcasts `ChangedEvent(action: updated)` on success.
  Future<StoredNote> patchProperties({
    required String id,
    required Map<String, Object?> set,
    required Set<String> unset,
    required String actor,
  }) {
    return _tracer.startActiveSpan(
      'note.write.patch_properties',
      attributes: {'note.id': id},
      (span) async {
        if (set.isEmpty && unset.isEmpty) {
          throw const PropertyValidationException([
            PropertyViolation(key: '', reason: 'no changes supplied'),
          ]);
        }
        final overlap = set.keys.toSet().intersection(unset);
        if (overlap.isNotEmpty) {
          throw PropertyValidationException([
            for (final key in overlap)
              PropertyViolation(
                  key: key, reason: 'key is in both set and unset'),
          ]);
        }
        final badKeys = {...set.keys, ...unset}.where(
          (k) => kReservedPropertyKeys.contains(k) || kBuiltinKeys.contains(k),
        );
        if (badKeys.isNotEmpty) {
          throw PropertyValidationException([
            for (final key in badKeys)
              PropertyViolation(key: key, reason: 'reserved key'),
          ]);
        }

        final current = await storage.read(id);
        if (set.isNotEmpty) {
          _validateCallerProperties(
            path: current.path,
            tags: computeTags(extra: current.extra, content: current.content),
            isDefinition: isDatabaseDefinitionExtra(current.extra),
            properties: set,
            selfId: id,
          );
        }

        final updated =
            await storage.patchExtra(id: id, set: set, unset: unset);
        final summary = updated.toSummary();
        metaIndex.upsert(summary);
        final coveringDefs = _coveringOf(updated, summary);
        linkIndex.upsert(
          updated.id,
          updated.content,
          extraLinks: _relationLinks(coveringDefs, updated.extra),
        );
        searchIndex.upsert(
          id: updated.id,
          title: updated.title,
          path: updated.path,
          content: updated.content,
          updatedAt: updated.updatedAt,
          tags: summary.tags,
          links: _searchLinkEdges(updated.id),
          extra: updated.extra,
          createdAt: updated.createdAt,
          isDefinition: isDatabaseDefinitionExtra(updated.extra),
        );
        _refreshRegistry(summary, updated.extra);
        _safeBroadcast(
          ChangedEvent(
            noteId: updated.id,
            version: updated.version,
            by: actor,
            action: ChangeAction.updated,
          ),
        );
        _log.info(
          'note ${updated.id} properties patched by $actor '
          '(version ${updated.version})',
        );
        return updated;
      },
    );
  }

  // ---------------------------------------------------------------------
  // Row and database creation (4.9, 4.10)
  // ---------------------------------------------------------------------

  /// Creates a new row of database [databaseId]: resolves the target
  /// [path] against the database's source (defaulting to the source
  /// folder, or the vault root for a tag source), rejects a [path] outside
  /// a folder source, validates [properties] against the database's
  /// definition, and adds the source tag for a tag source before
  /// delegating to [create].
  Future<StoredNote> createRow({
    required String databaseId,
    required String title,
    required String actor,
    Map<String, Object?> properties = const {},
    String content = '',
    String? path,
  }) {
    return _tracer.startActiveSpan('note.write.create_row', (span) async {
      final def = registry?.get(databaseId);
      if (def == null) throw DatabaseNotFoundException(databaseId);

      final source = def.source;
      String resolvedPath;
      final extra = <String, Object?>{...properties};
      if (source.folder != null) {
        final folder = source.folder!;
        resolvedPath = path ?? folder;
        final withinFolder = resolvedPath == folder ||
            (source.includeSubfolders && resolvedPath.startsWith('$folder/'));
        if (!withinFolder) {
          throw PathOutsideSourceException(path: resolvedPath, folder: folder);
        }
      } else {
        resolvedPath = path ?? '';
        extra['tags'] = [source.tag!];
      }

      final violations = validateProperties(
        [def],
        properties,
        resolveTitle: _resolveTitle,
        isRowOf: _isRowOf,
      );
      if (violations.isNotEmpty) throw PropertyValidationException(violations);

      return _persistCreate(
        title: title,
        content: content,
        actor: actor,
        path: resolvedPath,
        extra: extra,
        span: span,
      );
    });
  }

  /// Creates a new database definition note: builds `extra` as
  /// `{type: database, source, properties, views}`, validates it as a
  /// definition (structural parse + [validateDefinition]) before writing
  /// anything, then delegates to [create]'s storage/index/broadcast path.
  Future<StoredNote> createDatabase({
    required String title,
    required String actor,
    required DatabaseSource source,
    String path = '',
    String content = '',
    Map<String, PropertyDefinition> properties = const {},
    List<ViewDefinition> views = const [],
  }) {
    return _tracer.startActiveSpan('note.write.create_database', (span) async {
      final extra = _definitionExtra(
        source: source,
        properties: properties,
        views: views,
      );
      _validateDefinitionExtra(id: '', title: title, path: path, extra: extra);
      final note = await _persistCreate(
        title: title,
        content: content,
        actor: actor,
        path: path,
        extra: extra,
        span: span,
      );
      return note;
    });
  }

  /// Updates database [id]'s definition and/or body. When [source],
  /// [properties], and [views] are all omitted, this is a body-only write
  /// that preserves the existing `type`/`source`/`properties`/`views`
  /// untouched (per the `databases` spec's "a body-only update on a
  /// definition preserves ..." scenario); supplying any of the three
  /// replaces all three sections wholesale (a `PUT`, not a merge).
  ///
  /// Throws [NoteNotFoundException] if [id] does not name a note whose
  /// frontmatter carries `type: database`.
  Future<StoredNote> updateDatabase({
    required String id,
    required int ifMatch,
    required String actor,
    String? title,
    String? content,
    String? path,
    DatabaseSource? source,
    Map<String, PropertyDefinition>? properties,
    List<ViewDefinition>? views,
  }) {
    return _tracer.startActiveSpan(
      'note.write.update_database',
      attributes: {'note.id': id},
      (span) async {
        final current = await storage.read(id);
        if (!isDatabaseDefinitionExtra(current.extra)) {
          throw NoteNotFoundException(id);
        }
        final bodyOnly = source == null && properties == null && views == null;
        Map<String, Object?>? extra;
        if (!bodyOnly) {
          final currentSource = DatabaseSource.fromJson(
            (current.extra['source'] as Map?)?.cast<String, dynamic>() ??
                {'folder': current.path},
          );
          extra = _definitionExtra(
            source: source ?? currentSource,
            properties: properties ?? _parseDefinition(current).properties,
            views: views ?? _parseDefinition(current).views,
          );
          _validateDefinitionExtra(
            id: id,
            title: title ?? current.title,
            path: path ?? current.path,
            extra: extra,
          );
        }
        final updated = await updateRaw(
          id: id,
          title: title ?? current.title,
          content: content ?? current.content,
          ifMatch: ifMatch,
          actor: actor,
          path: path,
          properties: extra,
        );
        return updated;
      },
    );
  }

  /// Parses [note]'s current `extra` into a [DatabaseDefinition] purely to
  /// read back its `properties`/`views` sections for a body-only
  /// [updateDatabase] call that only changes one of the three sections —
  /// falls back to empty sections if parsing fails (shouldn't happen for a
  /// note that already passed [isDatabaseDefinitionExtra] and was
  /// previously written by [createDatabase]/[updateDatabase]).
  DatabaseDefinition _parseDefinition(StoredNote note) {
    try {
      return parseDatabaseDefinition(
        id: note.id,
        title: note.title,
        path: note.path,
        extra: note.extra,
      );
    } on DefinitionFormatException {
      return DatabaseDefinition(
        id: note.id,
        title: note.title,
        path: note.path,
        version: note.version,
        source: DatabaseSource.folder(note.path),
        properties: const {},
        views: const [],
        createdAt: note.createdAt,
        updatedAt: note.updatedAt,
      );
    }
  }

  Map<String, Object?> _definitionExtra({
    required DatabaseSource source,
    required Map<String, PropertyDefinition> properties,
    required List<ViewDefinition> views,
  }) =>
      {
        'type': 'database',
        'source': source.toJson(),
        'properties': {
          for (final entry in properties.entries)
            entry.key: entry.value.toJson(),
        },
        'views': [for (final v in views) v.toJson()],
      };

  void _validateDefinitionExtra({
    required String id,
    required String title,
    required String path,
    required Map<String, Object?> extra,
  }) {
    final DatabaseDefinition parsed;
    try {
      parsed = parseDatabaseDefinition(
        id: id,
        title: title,
        path: path,
        extra: extra,
      );
    } on DefinitionFormatException catch (e) {
      throw DefinitionValidationException([
        DefinitionViolation(path: '', reason: e.toString()),
      ]);
    }
    final violations = validateDefinition(parsed);
    if (violations.isNotEmpty) throw DefinitionValidationException(violations);
  }

  // ---------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------

  void _validateCallerProperties({
    required String path,
    required Set<String> tags,
    required bool isDefinition,
    required Map<String, Object?> properties,
    String? selfId,
  }) {
    final covering = registry?.covering(
          path,
          tags,
          noteId: selfId,
          isDefinition: isDefinition,
        ) ??
        const <DatabaseDefinition>[];
    final violations = validateProperties(
      covering,
      properties,
      resolveTitle: _resolveTitle,
      isRowOf: _isRowOf,
    );
    if (violations.isNotEmpty) throw PropertyValidationException(violations);
  }

  List<DatabaseDefinition> _coveringOf(StoredNote note, NoteSummary summary) =>
      registry?.covering(
        note.path,
        summary.tags,
        noteId: note.id,
        isDefinition: isDatabaseDefinitionExtra(note.extra),
      ) ??
      const <DatabaseDefinition>[];

  NoteSummary? _resolveTitle(String title) {
    final id = metaIndex.resolveTitle(title);
    return id == null ? null : metaIndex.get(id);
  }

  bool _isRowOf(NoteSummary note, String databaseId) =>
      registry
          ?.covering(note.path, note.tags, noteId: note.id)
          .any((d) => d.id == databaseId) ??
      false;

  /// Extracts wikilink [LinkEdge]s from every declared `relation`-typed
  /// property key present in [extra], per the `add-databases` design's
  /// "Relations feed the link index" decision. A relation value that isn't
  /// a `[[Title]]`/`[[Title|Alias]]` wikilink (or isn't a list at all) is
  /// silently skipped — [validateProperties] is what rejects a malformed
  /// relation value on a caller-supplied write; this method also runs on
  /// values that were never re-validated (e.g. after rename propagation),
  /// so it must tolerate whatever is already on disk. Only declared
  /// relation keys feed the index, so an undeclared frontmatter wikilink
  /// never becomes a backlink.
  List<LinkEdge> _relationLinks(
    List<DatabaseDefinition> definitions,
    Map<String, Object?> extra,
  ) {
    final relationKeys = <String>{
      for (final def in definitions)
        for (final entry in def.properties.entries)
          if (entry.value.type == PropertyType.relation) entry.key,
    };
    final edges = <LinkEdge>[];
    for (final key in relationKeys) {
      final value = extra[key];
      if (value is! List) continue;
      for (final item in value) {
        if (item is! String) continue;
        final parsed = parseLinks(item);
        if (parsed.length == 1 &&
            parsed.first.start == 0 &&
            parsed.first.end == item.length) {
          edges.add(
            LinkEdge(
              targetTitle: parsed.first.targetTitle,
              alias: parsed.first.alias,
            ),
          );
        }
      }
    }
    return edges;
  }

  /// Rewrites every `[[oldTitle]]`/`[[oldTitle|Alias]]` entry inside a
  /// declared relation property's value list in [extra] to target
  /// [newTitle], preserving any alias — the frontmatter counterpart to
  /// [rewriteLinks] for [_propagateRename]. Returns [extra] itself (same
  /// instance) when nothing changed, so the caller can cheaply detect a
  /// no-op with `identical`.
  Map<String, Object?> _rewriteRelationLinks(
    Map<String, Object?> extra,
    List<DatabaseDefinition> definitions, {
    required String oldTitle,
    required String newTitle,
  }) {
    final relationKeys = <String>{
      for (final def in definitions)
        for (final entry in def.properties.entries)
          if (entry.value.type == PropertyType.relation) entry.key,
    };
    Map<String, Object?>? next;
    for (final key in relationKeys) {
      final value = extra[key];
      if (value is! List) continue;
      List<Object?>? rewrittenList;
      for (var i = 0; i < value.length; i++) {
        final item = value[i];
        if (item is! String) continue;
        final parsed = parseLinks(item);
        if (parsed.length != 1 ||
            parsed.first.start != 0 ||
            parsed.first.end != item.length ||
            parsed.first.targetTitle != oldTitle) {
          continue;
        }
        final alias = parsed.first.alias;
        final rewrittenItem =
            alias == null ? '[[$newTitle]]' : '[[$newTitle|$alias]]';
        rewrittenList ??= List.of(value);
        rewrittenList[i] = rewrittenItem;
      }
      if (rewrittenList != null) {
        next ??= Map.of(extra);
        next[key] = rewrittenList;
      }
    }
    return next ?? extra;
  }

  /// Narrows [extra] to non-server-interpreted keys — used to pass a
  /// full replacement "properties" map to [Storage.update]/[updateRaw]
  /// when only a subset of property values changed (e.g. relation rename
  /// propagation), so keys that didn't change aren't dropped by
  /// [Storage.update]'s "supplied properties replaces the full set"
  /// merge rule.
  Map<String, Object?> _propertyKeysOnly(Map<String, Object?> extra) => {
        for (final entry in extra.entries)
          if (!kServerInterpretedKeys.contains(entry.key))
            entry.key: entry.value,
      };

  void _refreshRegistry(NoteSummary summary, Map<String, Object?> extra) {
    registry?.upsert(summary, extra);
  }
}
