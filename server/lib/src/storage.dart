import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/canonical_note_upload.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/excerpt.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/typed_proposals.dart'
    show TypedKnowledgeAcceptancePermit;
import 'package:server/src/markdown_blocks.dart';
import 'package:server/src/note_path.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/proposals/proposal_service.dart'
    show ProposalAcceptancePermit;
import 'package:server/src/tags.dart';
import 'package:ulid/ulid.dart';

export 'package:server/src/note_path.dart' show InvalidPathException;

part 'knowledge/accepted_group.dart';

/// Stable, sortable identifier for a note. Ulids are 26-character
/// Crockford base-32 strings.
typedef NoteId = String;

/// Filename of the marker written into a folder to make its existence
/// durable when it holds no notes yet (see `notes-storage`'s "Empty
/// folders are persisted via a marker file"). Deliberately not a `.md`
/// file so it is never mistaken for a note by any note-shaped scan.
const String kFolderMarkerFilename = '.folder';

/// Result of [Storage.createFolder]: the canonical, normalized folder
/// path, and whether this call is what brought it into existence.
@immutable
class FolderCreateResult {
  /// Creates a folder-creation result.
  const FolderCreateResult({required this.path, required this.created});

  /// Canonical `/`-separated folder path. When the folder already existed
  /// under a different case/normalization, this is the pre-existing
  /// spelling, not the one that was requested.
  final String path;

  /// `true` if this call created the folder (and its marker); `false` if
  /// it already existed (with notes, a marker, or both).
  final bool created;
}

/// A non-note file discovered under [Storage.contentDir] — an upload,
/// not a note. Tracked the same lightweight way an empty-folder marker
/// is (a set rebuilt on scan), not with the full id/title/tag machinery
/// [NoteSummary] carries, since a file has none of that.
@immutable
class StoredFile {
  /// Creates a file record.
  const StoredFile({
    required this.relativePath,
    required this.size,
    required this.updatedAt,
  });

  /// `/`-separated path relative to [Storage.contentDir], e.g.
  /// `"Ideas/diagram.png"`.
  final String relativePath;

  /// Size in bytes.
  final int size;

  /// Filesystem modification time.
  final DateTime updatedAt;
}

/// Metadata-only view of a note (no body). Returned by [Storage.list].
@immutable
class NoteSummary {
  /// Creates a summary; consumers do not normally call this directly.
  const NoteSummary({
    required this.id,
    required this.title,
    required this.path,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.tags = const <String>{},
    this.excerpt = '',
  });

  /// Note identifier (ULID).
  final NoteId id;

  /// Note title from frontmatter.
  final String title;

  /// Folder the note lives in, `/`-separated, no leading/trailing slash.
  /// Empty string means the vault root.
  final String path;

  /// Monotonically incremented version. New notes start at `1`.
  final int version;

  /// First write time, in UTC.
  final DateTime createdAt;

  /// Most recent write time, in UTC.
  final DateTime updatedAt;

  /// Computed tag set (frontmatter `tags` merged with inline `#tag`
  /// tokens; see `tags.dart`'s `computeTags`). Derived, not its own
  /// source of truth: [Storage] never persists this separately from the
  /// note's frontmatter/content, so it is always recomputed by
  /// [StoredNote.toSummary] from whatever is currently on disk.
  final Set<String> tags;

  /// Bounded, markdown-stripped preview of the note's body (see
  /// `excerpt.dart`'s `computeExcerpt`). Derived the same way as [tags]:
  /// never persisted, always recomputed by [StoredNote.toSummary].
  final String excerpt;
}

/// Full on-disk view of a note: required metadata + body + any extra
/// frontmatter keys preserved verbatim from the file.
@immutable
class StoredNote {
  /// Creates a stored-note value object.
  const StoredNote({
    required this.id,
    required this.title,
    required this.path,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.content,
    this.extra = const {},
  });

  /// Note identifier (ULID).
  final NoteId id;

  /// Note title.
  final String title;

  /// Folder the note lives in, `/`-separated, no leading/trailing slash.
  /// Empty string means the vault root.
  final String path;

  /// Monotonically incremented version.
  final int version;

  /// First write time (UTC).
  final DateTime createdAt;

  /// Most recent write time (UTC).
  final DateTime updatedAt;

  /// Markdown body verbatim.
  final String content;

  /// Frontmatter keys other than the v1 required set (`id`, `title`,
  /// `path`, `version`, `created_at`, `updated_at`). Storage round-trips
  /// this map unchanged so external tools can extend the schema without
  /// losing data. Insertion order matches the source file.
  final Map<String, Object?> extra;

  /// Returns a [NoteSummary] derived from this note, recomputing its tag
  /// set and excerpt from [extra]/[content] (see [computeTags],
  /// [computeExcerpt]) rather than caching either anywhere — this is what
  /// makes them "recalculated on every write and on startup index rebuild"
  /// per `notes-storage` spec: every caller of `toSummary()`
  /// (`Storage.list`, and `NoteWriteService` on every create/update) gets a
  /// fresh computation for free.
  NoteSummary toSummary() => NoteSummary(
        id: id,
        title: title,
        path: path,
        version: version,
        createdAt: createdAt,
        updatedAt: updatedAt,
        tags: computeTags(extra: extra, content: content),
        excerpt: computeExcerpt(content),
      );
}

/// Restore precondition failed against latest accepted version or tombstone.
class HistoryVersionConflictException implements Exception {
  /// Records the latest version without inventing live deleted content.
  HistoryVersionConflictException(this.currentVersion);

  /// Latest accepted note or deletion tombstone version.
  final int currentVersion;
}

/// Thrown by [Storage.read] / [Storage.update] / [Storage.delete] when the
/// requested id has no file on disk.
class NoteNotFoundException implements Exception {
  /// Creates a not-found exception for [id].
  NoteNotFoundException(this.id);

  /// The id that did not resolve.
  final NoteId id;

  @override
  String toString() => 'NoteNotFoundException: $id';
}

/// Thrown by [Storage.update] when the supplied `ifMatch` version does not
/// match the on-disk version.
@immutable
class VersionConflictException implements Exception {
  /// Creates a conflict carrying the [current] state of the note so the
  /// API layer can return both versions to the client.
  VersionConflictException({
    required this.current,
    required this.suppliedIfMatch,
  }) : message = 'version_conflict: client sent If-Match $suppliedIfMatch but '
            'the current version is ${current.version}';

  /// On-disk note state at the time of the conflict.
  final StoredNote current;

  /// `If-Match` value the client sent.
  final int suppliedIfMatch;

  /// Human-readable description.
  final String message;

  @override
  String toString() => 'VersionConflictException: $message';
}

/// Thrown by [Storage.create] / [Storage.update] when the computed target
/// file path (folder + sanitized title) already belongs to a different
/// note. Comparison is case-insensitive and NFC-normalized (see
/// `note_path.dart`), matching the filesystems this app targets.
@immutable
class PathConflictException implements Exception {
  /// Creates a conflict naming the [path]/[title] that collided.
  const PathConflictException({required this.path, required this.title});

  /// The folder that was requested.
  final String path;

  /// The title that produced a colliding filename.
  final String title;

  @override
  String toString() => 'PathConflictException: $path/$title';
}

/// A revision predates block metadata or its canonical source was changed.
class BlockMapUnavailableException implements Exception {
  /// Reports whether persisted metadata conflicts with the current source.
  const BlockMapUnavailableException({this.stale = false});

  /// True when the accepted map differs from the inspected canonical source.
  final bool stale;
}

/// File-backed note store. Owns the `<dataDir>/content/` directory and is
/// the canonical source of truth for note bodies and metadata. Higher
/// layers (notes API, search index, lock manager) call into this class
/// for every read and write.
///
/// Notes are stored at `<contentDir>/<path>/<sanitized-title>.md`. `id`
/// is permanent and lives only in frontmatter — it is never part of the
/// filename, so a title or path change renames/moves the file in place
/// without changing the note's identity or its `/notes/{id}` address.
///
/// Concurrency: every mutating operation on a given id is serialized
/// through a per-id mutex so two updates to the same note cannot
/// interleave their tmp + rename sequences (as before). Additionally,
/// the "does the target path already exist" check and the write that
/// follows it are serialized through a second mutex keyed by the
/// *target path*, so two different notes racing to the same computed
/// filename can't both pass the check before either writes — exactly one
/// succeeds and the other observes [PathConflictException].
class Storage {
  /// Creates a storage rooted at [contentDir]. The directory is created
  /// on first write if it does not yet exist.
  Storage({
    required this.contentDir,
    Clock clock = const Clock(),
    NoteId Function()? idGenerator,
    Logger? logger,
    this.beforeHistoryApply,
    this.afterHistoryPublish,
    this.acceptedPolicyReplay,
  })  : _clock = clock,
        _idGenerator = idGenerator ?? _ulid,
        _log = logger ?? Logger('storage');

  /// Filesystem directory holding `*.md` note files (recursively, under
  /// per-note folders).
  final Directory contentDir;

  /// Failure injection after durable intent, before canonical publication.
  @visibleForTesting
  final Future<void> Function()? beforeHistoryApply;

  /// Failure injection after canonical publication, before snapshot commit.
  @visibleForTesting
  final Future<void> Function()? afterHistoryPublish;

  /// Replays an authorized note designation before pending history is cleared.
  Future<void> Function(Map<String, dynamic> delta)? acceptedPolicyReplay;

  Directory get _historyDir => Directory('${contentDir.path}.history');
  final _blockReconciler = MarkdownBlockReconciler();
  Future<void>? _historyRecovery;
  bool _historyFaulted = false;

  File get _historyDirty => File('${_historyDir.path}/index-dirty');

  Directory get _historyIndexPending =>
      Directory('${_historyDir.path}/index-pending');

  File _historyIndexTicket(String id, int version) => File(
        '${_historyIndexPending.path}/${base64Url.encode(utf8.encode(id))}-$version',
      );

  /// Indicates accepted history may be newer than persisted search data.
  bool get historyNeedsReindex =>
      _historyDirty.existsSync() ||
      (_historyIndexPending.existsSync() &&
          _historyIndexPending.listSync().isNotEmpty);

  /// Acknowledges only the indexed accepted revision, preserving other writes.
  Future<void> acknowledgeIndexedRevision(String id, int version) async {
    final ticket = _historyIndexTicket(id, version);
    if (ticket.existsSync()) await ticket.delete();
  }

  /// Prepares canonical notes before derived indices open.
  Future<void> prepareHistory() => _ensureIndexed();

  /// Clears startup invalidation only after rebuilding search successfully.
  Future<void> acknowledgeHistoryReindex() async {
    if (_historyDirty.existsSync()) await _historyDirty.delete();
    if (_historyIndexPending.existsSync()) {
      await _historyIndexPending.delete(recursive: true);
    }
  }

  final Clock _clock;
  final NoteId Function() _idGenerator;
  final Logger _log;

  // Per-id write serialization (unchanged from before path support).
  final Map<NoteId, Future<void>> _locks = {};
  final Object _noteTransactionZone = Object();

  // Per-target-path write serialization: keyed by `collisionKey` of the
  // relative file path a write is about to claim. Guards the
  // check-then-write span in [_claim] against a second note racing to
  // the same filename.
  final Map<String, Future<void>> _pathLocks = {};

  // id -> relative file path (e.g. "Projects/Alpha/Meeting Notes.md"),
  // relative to [contentDir]. Lazily built by [_ensureIndexed] and kept
  // current by every create/update/delete. This is what lets `read`,
  // `update`, and `delete` find a note's file by id in O(1) once the
  // process-lifetime cache is warm, without id being encoded in the
  // filename.
  final Map<NoteId, String> _relPathById = {};

  // collisionKey(relative file path) -> owning id. The reverse of
  // [_relPathById], used for O(1) collision detection.
  final Map<String, NoteId> _idByKey = {};

  // Folder paths (relative to [contentDir], `/`-joined) known to hold a
  // [kFolderMarkerFilename] marker. Populated by [_scanAll] and kept
  // current by [createFolder], mirroring how [_relPathById] is populated
  // by [_scanAll] and kept current by [_claim].
  final Set<String> _emptyFolderPaths = {};

  // Non-note files discovered under contentDir (uploads), keyed by
  // relative path. Populated by [_scanAll]; kept current at runtime by
  // [registerFile] rather than a full rescan.
  final Map<String, StoredFile> _files = {};

  Future<void>? _indexBuild;

  /// Folder paths currently known to hold an empty-folder marker (see
  /// [kFolderMarkerFilename]). A path may appear here and also have notes
  /// in it — the marker is not removed once notes exist alongside it.
  Set<String> get emptyFolderPaths => Set.unmodifiable(_emptyFolderPaths);

  /// Every non-note file currently known (uploads), in no particular
  /// order. See [filesIn] to narrow to a single folder.
  Iterable<StoredFile> get files => _files.values;

  /// Direct (non-recursive) file children of [folderPath] (`/`-separated,
  /// no leading/trailing slash; empty string means the vault root).
  List<StoredFile> filesIn(String folderPath) => [
        for (final file in _files.values)
          if (_folderOf(file.relativePath) == folderPath) file,
      ];

  /// Registers [file] (e.g. right after a write completes) without a
  /// full [_scanAll], mirroring how [createFolder] updates
  /// [_emptyFolderPaths] in place.
  void registerFile(StoredFile file) => _files[file.relativePath] = file;

  /// Lists every well-formed note in the store as a metadata summary.
  ///
  /// Files that fail to parse (broken YAML, missing required keys) are
  /// logged and skipped; callers SHOULD treat the index as best-effort
  /// and surface the malformed-file warning to operators.
  Future<List<NoteSummary>> list() async {
    final notes = await _scanAll();
    _indexBuild ??= Future.value();
    return [for (final n in notes) n.toSummary()];
  }

  /// Reads the note with [id], throwing [NoteNotFoundException] if no
  /// such file exists or [FrontmatterFormatException] if the file is
  /// malformed.
  Future<StoredNote> read(NoteId id) async {
    final file = await _locate(id);
    return _readFile(file);
  }

  /// Creates a new note with the supplied [title] and [content] under
  /// [path] (defaulting to the vault root), assigns it a fresh ULID,
  /// stamps `created_at` / `updated_at` from the clock, and writes it
  /// atomically. Returns the stored note (version 1).
  ///
  /// Throws [PathConflictException] if the resolved `<path>/<title>.md`
  /// already belongs to a different note.
  ///
  /// [properties] becomes the note's `extra` verbatim: since a freshly
  /// created note has no prior frontmatter, there is nothing to merge —
  /// see [update] for the merge behavior a second write applies. Callers
  /// writing declared row properties pass just those key/value pairs;
  /// callers writing a database definition (or other server-interpreted
  /// keys such as `tags`) pass those directly in the same map, since
  /// [Storage] itself does not distinguish "property" keys from
  /// server-interpreted ones on create — that distinction only matters
  /// once there is existing state to preserve, in [update].
  Future<StoredNote> create({
    required String title,
    required String content,
    String? actor,
    String path = '',
    Map<String, Object?>? properties,
  }) async {
    await _ensureIndexed();
    final id = _idGenerator();
    final relPath = _relativeFilePath(path: path, title: title);
    final key = collisionKey(relPath);
    return _withPathLock(key, () async {
      final owner = _idByKey[key];
      if (owner != null) {
        throw PathConflictException(path: path, title: title);
      }
      final now = _clock.nowUtc();
      final note = StoredNote(
        id: id,
        title: title,
        path: path,
        version: 1,
        createdAt: now,
        updatedAt: now,
        content: content,
        extra: properties ?? const {},
      );
      await _writeAtNewLocation(note, relPath, actor: actor);
      _claim(id: id, key: key, relPath: relPath);
      return note;
    });
  }

  /// Updates [id] in place. The supplied [ifMatch] SHALL equal the
  /// on-disk version; otherwise [VersionConflictException] is raised
  /// carrying the current state. Unknown frontmatter keys are preserved.
  ///
  /// When [path] is omitted, the note's folder is unchanged. When
  /// [title] or [path] changes the effective target filename, the
  /// backing file is renamed/moved as part of this same write. Throws
  /// [PathConflictException] (without changing anything on disk) if the
  /// new target already belongs to a different note.
  /// When [properties] is omitted (`null`), [content] is written and every
  /// existing `extra` key is preserved unchanged. When [properties] is
  /// supplied (even as `{}`), the note's `extra` is rebuilt: a key already
  /// present in [properties] takes its new value (this is how a
  /// server-interpreted key such as `type`/`source`/`properties`/`views` is
  /// replaced, e.g. by a database definition update); a server-interpreted
  /// key ([_serverInterpretedExtraKeys]) NOT present in [properties] is
  /// preserved automatically; any other existing key not present in
  /// [properties] is dropped (this is how a `properties`-replacing write
  /// removes property keys the caller no longer sent). Key order is
  /// preserved for keys that remain; brand-new keys are appended.
  Future<StoredNote> update({
    required NoteId id,
    required String title,
    required String content,
    required int ifMatch,
    String? actor,
    String? path,
    Map<String, Object?>? properties,
  }) {
    return _withLock(id, () async {
      await _ensureIndexed();
      final current = await read(id);
      if (current.version != ifMatch) {
        throw VersionConflictException(
          current: current,
          suppliedIfMatch: ifMatch,
        );
      }
      final effectivePath = path ?? current.path;
      final newRelPath = _relativeFilePath(path: effectivePath, title: title);
      final newKey = collisionKey(newRelPath);
      final oldRelPath = _relPathById[id]!;
      final oldKey = collisionKey(oldRelPath);

      return _withPathLock(newKey, () async {
        final owner = _idByKey[newKey];
        if (owner != null && owner != id) {
          throw PathConflictException(path: effectivePath, title: title);
        }
        final now = _clock.nowUtc();
        final next = StoredNote(
          id: id,
          title: title,
          path: effectivePath,
          version: current.version + 1,
          createdAt: current.createdAt,
          updatedAt: now,
          content: content,
          extra: _rebuildExtra(current.extra, properties),
        );
        if (newRelPath == oldRelPath) {
          await _writeAtNewLocation(next, newRelPath, actor: actor);
        } else {
          await _writeAtNewLocation(next, newRelPath, actor: actor);
          final oldFile = _fileForRelative(oldRelPath);
          if (oldFile.existsSync()) await oldFile.delete();
          _idByKey.remove(oldKey);
        }
        _claim(id: id, key: newKey, relPath: newRelPath);
        return next;
      });
    });
  }

  /// Merges `existing` (freshly read via [update]) with the caller's
  /// [set]/[unset], runs the whole read-modify-write inside the same
  /// per-id mutex [update] uses (see [_withLock]) so a concurrent `PUT`
  /// and a property patch serialize instead of racing, bumps `version` and
  /// `updated_at`, and writes the file atomically. Never touches `content`,
  /// and needs no `ifMatch` — the mutex is what makes this safe, per the
  /// `add-databases` design's "Property patch is a new
  /// `NoteWriteService.patchProperties`" decision.
  ///
  /// [set] entries are applied after [unset] removals, so a key present in
  /// both ends up set (callers SHOULD reject that combination earlier, at
  /// the validation layer, rather than relying on this ordering).
  Future<StoredNote> patchExtra({
    required NoteId id,
    String? actor,
    Map<String, Object?> set = const {},
    Set<String> unset = const {},
  }) {
    return _withLock(id, () async {
      await _ensureIndexed();
      final current = await read(id);
      final nextExtra = {...current.extra};
      for (final key in unset) {
        nextExtra.remove(key);
      }
      nextExtra.addAll(set);
      final now = _clock.nowUtc();
      final next = StoredNote(
        id: current.id,
        title: current.title,
        path: current.path,
        version: current.version + 1,
        createdAt: current.createdAt,
        updatedAt: now,
        content: current.content,
        extra: nextExtra,
      );
      final relPath = _relPathById[id]!;
      await _writeAtNewLocation(next, relPath, actor: actor);
      return next;
    });
  }

  /// Deletes the file backing [id]. Idempotent: deleting a missing id
  /// throws [NoteNotFoundException].
  Future<void> delete(NoteId id, {String? actor}) {
    return _withLock(id, () async {
      final file = await _locate(id);
      final current = await _readFile(file);
      if (await _retainsHistory(current)) {
        await _commitHistory(current, null, deleted: true, actor: actor);
      } else {
        await file.delete();
      }
      final relPath = _relPathById.remove(id);
      if (relPath != null) _idByKey.remove(collisionKey(relPath));
    });
  }

  /// Resolves [id] to its current file, populating the id index first if
  /// it hasn't been built yet in this process.
  Future<File> _locate(NoteId id) async {
    await _ensureIndexed();
    final rel = _relPathById[id];
    if (rel == null) throw NoteNotFoundException(id);
    return _fileForRelative(rel);
  }

  /// Builds [_relPathById] / [_idByKey] once per process lifetime (unless
  /// a fresh [list] scan replaces them), by recursively walking
  /// [contentDir]. Concurrent callers await the same in-flight build
  /// rather than triggering redundant scans.
  Future<void>? _groupPublication;
  final Object _groupZone = Object();

  Future<void> _ensureIndexed() {
    final publication = _groupPublication;
    if (publication != null && Zone.current[_groupZone] != true) {
      return publication.then((_) => _ensureIndexed());
    }
    _assertHistoryHealthy();
    if (_relPathById.isNotEmpty || _indexBuild != null) {
      return _indexBuild ?? Future.value();
    }
    final build = _scanAll();
    _indexBuild = build.then((_) {});
    return _indexBuild!;
  }

  Future<List<StoredNote>> _scanAll() async {
    _assertHistoryHealthy();
    await (_historyRecovery ??= _recoverHistory());
    _relPathById.clear();
    _idByKey.clear();
    _emptyFolderPaths.clear();
    _files.clear();
    final notes = <StoredNote>[];
    if (!contentDir.existsSync()) return notes;
    await for (final entity in contentDir.list(recursive: true)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('/$kFolderMarkerFilename')) {
        _emptyFolderPaths.add(_folderOf(_relativePathOf(entity)));
        continue;
      }
      if (entity.path.endsWith('.tmp')) continue;
      if (!entity.path.endsWith('.md') ||
          !await isCanonicalNotePayload(entity)) {
        final rel = _relativePathOf(entity);
        final stat = entity.statSync();
        _files[rel] = StoredFile(
          relativePath: rel,
          size: stat.size,
          updatedAt: stat.modified,
        );
        continue;
      }
      try {
        final note = await _readFile(entity);
        final rel = _relativePathOf(entity);
        notes.add(note);
        _relPathById[note.id] = rel;
        _idByKey[collisionKey(rel)] = note.id;
      } on Exception catch (e) {
        _log.warning('Skipping malformed note ${entity.path}: $e');
      }
    }
    notes.sort((a, b) => a.id.compareTo(b.id));
    return notes;
  }

  /// Creates an empty folder at [path] (and any missing intermediate
  /// folders), persisted via a [kFolderMarkerFilename] marker so it
  /// survives a restart even with no notes in it. Idempotent: a [path]
  /// that already resolves (per [collisionKey]) to a folder that holds
  /// notes, an existing marker, or both returns that folder's canonical
  /// path with `created: false` and touches nothing on disk.
  ///
  /// Throws [InvalidPathException] if any segment of [path] is invalid
  /// (see [sanitizedPathSegments]).
  Future<FolderCreateResult> createFolder(String path) async {
    await _ensureIndexed();
    final segments = sanitizedPathSegments(path);
    final normalized = segments.join('/');
    final key = collisionKey(normalized);
    return _withPathLock(key, () async {
      final existing = _resolveExistingFolderPath(key);
      if (existing != null) {
        return FolderCreateResult(path: existing, created: false);
      }
      final dir = Directory('${contentDir.path}/$normalized');
      await dir.create(recursive: true);
      final marker = File('${dir.path}/$kFolderMarkerFilename');
      if (!marker.existsSync()) await marker.create();
      _emptyFolderPaths.add(normalized);
      return FolderCreateResult(path: normalized, created: true);
    });
  }

  // Finds a folder already known to the index (via a note's containing
  // folder or an existing marker) whose collisionKey matches [key],
  // returning its canonical (as-stored) path, or `null` if none matches.
  String? _resolveExistingFolderPath(String key) {
    for (final relPath in _relPathById.values) {
      final folder = _folderOf(relPath);
      if (collisionKey(folder) == key) return folder;
    }
    for (final marker in _emptyFolderPaths) {
      if (collisionKey(marker) == key) return marker;
    }
    return null;
  }

  // Directory portion of a relative note file path, e.g.
  // "Projects/Alpha/Note.md" -> "Projects/Alpha", "Note.md" -> "".
  String _folderOf(String relPath) {
    final idx = relPath.lastIndexOf('/');
    return idx < 0 ? '' : relPath.substring(0, idx);
  }

  Future<StoredNote> _readFile(File file) async {
    final text = await file.readAsString();
    final fm = parseFrontmatter(text);
    return _toStoredNote(fm, file.path);
  }

  StoredNote _toStoredNote(Frontmatter fm, String filePath) {
    final meta = fm.metadata;
    final id = meta['id'];
    final title = meta['title'];
    final version = meta['version'];
    final createdRaw = meta['created_at'];
    final updatedRaw = meta['updated_at'];
    if (id is! String ||
        title is! String ||
        version is! int ||
        createdRaw is! String ||
        updatedRaw is! String) {
      throw FrontmatterFormatException(
        'Note $filePath is missing one of: id, title, version, created_at, '
        'updated_at',
      );
    }
    // `path` is read leniently (defaulting to "") rather than required:
    // a file written before this field existed, or a fixture that omits
    // it, is still a valid note — the legacy-layout migration is what
    // brings existing files up to date with an explicit `path` key.
    final pathRaw = meta['path'];
    final path = pathRaw is String ? pathRaw : '';
    final extra = <String, Object?>{};
    for (final entry in meta.entries) {
      if (_reservedKeys.contains(entry.key)) continue;
      extra[entry.key] = entry.value;
    }
    return StoredNote(
      id: id,
      title: title,
      path: path,
      version: version,
      createdAt: DateTime.parse(createdRaw).toUtc(),
      updatedAt: DateTime.parse(updatedRaw).toUtc(),
      content: fm.body,
      extra: extra,
    );
  }

  /// Writes [note] to [relPath] via the standard tmp + fsync + rename
  /// sequence, creating parent directories as needed. Used for both
  /// in-place saves (relPath unchanged) and moves/renames (relPath is
  /// the new location) — in both cases the rename to the final path is
  /// the same atomic step, so a crash never leaves a torn or missing
  /// canonical file at the final location.
  Future<void> _writeAtNewLocation(
    StoredNote note,
    String relPath, {
    String? actor,
  }) async {
    final finalFile = _fileForRelative(relPath);
    final parent = finalFile.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    final fm = Frontmatter(
      metadata: _buildMetadataMap(note),
      body: note.content,
    );
    final text = serializeFrontmatter(fm);

    if (await _retainsHistory(note)) {
      await _commitHistory(note, relPath, actor: actor);
      return;
    }
    await validateKnowledgeMutation?.call(note, note.id, reviewed: false);
    final tmp = File('${finalFile.path}.tmp');
    final raf = await tmp.open(mode: FileMode.writeOnly);
    try {
      await raf.writeString(text);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(finalFile.path);
  }

  Directory _noteHistory(String id) => Directory(
        '${_historyDir.path}/${base64Url.encode(utf8.encode(id))}',
      );

  /// Server policy can require history independently of editable frontmatter.
  bool Function(StoredNote note)? requiresHistoryForNote;

  File _requiredHistoryMarker(String id) =>
      File('${_historyDir.path}/required/${base64Url.encode(utf8.encode(id))}');

  /// Pins retention outside purgeable snapshots without creating a revision.
  Future<void> ensureRequiredHistory(String id) =>
      _atomicText(_requiredHistoryMarker(id), '');

  Future<bool> _retainsHistory(StoredNote note) async {
    if (requiresHistoryForNote?.call(note) ?? false) {
      await ensureRequiredHistory(note.id);
    }
    return note.extra['history'] == true ||
        _noteHistory(note.id).existsSync() ||
        _requiredHistoryMarker(note.id).existsSync();
  }

  /// Captures an accepted baseline without rewriting an immutable snapshot.
  /// Legacy snapshots lacking block metadata get a new no-op accepted revision.
  Future<StoredNote> enableRevisionHistory(String id, {String? actor}) =>
      _withLock(id, () async {
        await _ensureIndexed();
        final current = await read(id);
        await ensureRequiredHistory(id);
        final snapshot =
            File('${_noteHistory(id).path}/${current.version}.json');
        if (!snapshot.existsSync()) {
          await _commitHistory(
            current,
            _relPathById[id],
            actor: actor,
            captureCurrent: true,
          );
          return current;
        }
        final accepted =
            jsonDecode(await snapshot.readAsString()) as Map<String, dynamic>;
        final rawMap = accepted['block_map'];
        if (rawMap is Map<String, dynamic> &&
            MarkdownBlockMap.fromJson(rawMap).matches(current.content)) {
          return current;
        }
        final next = StoredNote(
          id: current.id,
          title: current.title,
          path: current.path,
          version: current.version + 1,
          createdAt: current.createdAt,
          updatedAt: _clock.nowUtc(),
          content: current.content,
          extra: current.extra,
        );
        await _commitHistory(next, _relPathById[id], actor: actor);
        return next;
      });

  /// Records a baseline block map for a note whose current accepted revision
  /// was saved without history, so ordinary notes can receive block-level
  /// proposals. Content and version stay unchanged; later saves keep the map
  /// current. Returns false when the current revision already has a snapshot.
  Future<bool> captureBlockMapBaseline(String id, {String? actor}) =>
      _withLock(id, () async {
        await _ensureIndexed();
        final current = await read(id);
        final snapshot =
            File('${_noteHistory(id).path}/${current.version}.json');
        if (snapshot.existsSync()) return false;
        await _commitHistory(
          current,
          _relPathById[id],
          actor: actor,
          captureCurrent: true,
        );
        return true;
      });

  Directory _proposalDirectory(String id) =>
      Directory('${_noteHistory(id).path}/proposals');

  File _proposalFile(String noteId, String proposalId) => File(
        '${_proposalDirectory(noteId).path}/'
        '${base64Url.encode(utf8.encode(proposalId))}.json',
      );

  /// Serializes review work with every accepted mutation of the same note.
  /// Nested storage operations retain this lock only while [body] is awaited.
  Future<T> withProposalMutation<T>(String id, Future<T> Function() body) =>
      _withLock(id, () async {
        await _ensureIndexed();
        return body();
      });

  /// Reads server-owned review state after accepted journal recovery.
  Future<ProposalRecord> readProposalRecord(String noteId, String proposalId) =>
      withProposalMutation(noteId, () async {
        final file = _proposalFile(noteId, proposalId);
        if (!file.existsSync()) throw NoteNotFoundException(noteId);
        final record = ProposalRecord.fromStoredJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        );
        if (record.id != proposalId || record.noteId != noteId) {
          throw const FormatException('Proposal identity mismatch');
        }
        return record;
      });

  /// Lists review records without putting candidates in canonical note scans.
  Future<List<ProposalRecord>> proposalRecords({String? noteId}) async {
    await _ensureIndexed();
    final directories = noteId != null
        ? [_proposalDirectory(noteId)]
        : (!_historyDir.existsSync()
            ? <Directory>[]
            : (await _historyDir.list().toList())
                .whereType<Directory>()
                .map((directory) => Directory('${directory.path}/proposals'))
                .toList());
    final records = <ProposalRecord>[];
    for (final directory in directories) {
      if (!directory.existsSync()) continue;
      await for (final file in directory.list()) {
        if (file is File && file.path.endsWith('.json')) {
          records.add(
            ProposalRecord.fromStoredJson(
              jsonDecode(await file.readAsString()) as Map<String, dynamic>,
            ),
          );
        }
      }
    }
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records;
  }

  /// Saves pending activity with CAS; accepted state requires the journal.
  Future<void> writeProposalRecord(
    ProposalRecord record, {
    int? expectedRecordRevision,
  }) =>
      withProposalMutation(record.noteId, () async {
        final file = _proposalFile(record.noteId, record.id);
        ProposalRecord? previous;
        if (file.existsSync()) {
          previous = await readProposalRecord(record.noteId, record.id);
        }
        if (previous?.recordRevision != expectedRecordRevision) {
          throw const ProposalRecordConflictException('record_changed');
        }
        if (record.state == 'accepted' && previous?.state != 'accepted') {
          throw StateError('Accepted proposal requires journal publication');
        }
        await _atomicText(file, jsonEncode(record.toStoredJson()));
      });

  /// Loads immutable accepted-block comment events, independent of proposals.
  Future<Map<String, dynamic>> readBlockComments(String id) =>
      withProposalMutation(id, () async {
        final file = File('${_noteHistory(id).path}/comments.json');
        if (!file.existsSync()) {
          return {'record_revision': 0, 'items': <Object?>[]};
        }
        return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      });

  /// Appends accepted-block activity under the same canonical note lock.
  Future<void> writeBlockComments(
    String id,
    Map<String, dynamic> next, {
    required int expectedRecordRevision,
  }) =>
      withProposalMutation(id, () async {
        final current = await readBlockComments(id);
        if (current['record_revision'] != expectedRecordRevision ||
            next['record_revision'] != expectedRecordRevision + 1) {
          throw const ProposalRecordConflictException('comments_changed');
        }
        await _atomicText(
          File('${_noteHistory(id).path}/comments.json'),
          jsonEncode(next),
        );
      });

  /// Reads accepted source associations without any pending candidate data.
  Future<Map<String, dynamic>> readAcceptedProvenance(
    String id, {
    int? version,
  }) =>
      withProposalMutation(id, () async {
        final wanted = version ?? (await read(id)).version;
        final snapshot = File('${_noteHistory(id).path}/$wanted.json');
        if (!snapshot.existsSync()) return {};
        final event = jsonDecode(await snapshot.readAsString()) as Map;
        return (event['accepted_provenance'] as Map?)
                ?.cast<String, dynamic>() ??
            {};
      });

  /// Consumes authority issued only by the trusted review service.
  /// Journals canonical source and final review state together.
  Future<void> acceptProposal(
    ProposalAcceptancePermit permit, {
    required int expectedRecordRevision,
  }) =>
      withProposalMutation(permit.note.id, () async {
        permit.claim(this);
        final id = permit.note.id;
        final record = await readProposalRecord(id, permit.record.id);
        if (record.recordRevision != expectedRecordRevision ||
            !const {'pending', 'changes_requested'}.contains(record.state) ||
            permit.record.state != 'accepted' ||
            permit.record.acceptedVersion != permit.blockMap.version) {
          throw const ProposalRecordConflictException('record_changed');
        }
        if (permit.newNote) {
          if (_relPathById.containsKey(id) || permit.note.version != 1) {
            throw const ProposalRecordConflictException(
              'draft_already_created',
            );
          }
        } else {
          final current = await read(id);
          await readBlockMap(id);
          if (!permit.matchesCurrent(current)) {
            throw const ProposalRecordConflictException(
              'accepted_source_changed',
            );
          }
          if (current.version != permit.blockMap.version - 1 ||
              current.title != permit.note.title ||
              current.path != permit.note.path) {
            throw VersionConflictException(
              current: current,
              suppliedIfMatch: permit.blockMap.version - 1,
            );
          }
        }
        final body = permit.deleted ? '' : permit.note.content;
        if (!permit.blockMap.matches(body) ||
            (!permit.deleted &&
                permit.note.version != permit.blockMap.version)) {
          throw StateError('Reviewed source does not match accepted block map');
        }
        final path = permit.deleted
            ? null
            : _relativeFilePath(
                path: permit.note.path,
                title: permit.note.title,
              );
        final key = path == null ? 'deleted:$id' : collisionKey(path);
        await _withPathLock(key, () async {
          final owner = path == null ? null : _idByKey[key];
          if (owner != null && owner != id) {
            throw PathConflictException(
              path: permit.note.path,
              title: permit.note.title,
            );
          }
          if (permit.requiresHistory) await ensureRequiredHistory(id);
          await _commitHistory(
            permit.note,
            path,
            deleted: permit.deleted,
            actor: permit.actor,
            reviewedBlockMap: permit.blockMap,
            acceptedProposal: permit.record,
            acceptedProvenance: permit.provenance,
            acceptedPolicyDelta: permit.policyDelta,
          );
          if (path == null) {
            final oldPath = _relPathById.remove(id);
            if (oldPath != null) _idByKey.remove(collisionKey(oldPath));
          } else {
            _claim(id: id, key: key, relPath: path);
          }
        });
      });

  /// Consumes a validated typed-group permit and publishes ordinary notes
  /// together.
  Future<void> acceptTypedKnowledge(
    TypedKnowledgeAcceptancePermit permit,
  ) async {
    await _ensureIndexed();
    permit.claim(this);
    final completer = Completer<void>();
    _groupPublication = completer.future;
    try {
      await runZoned(
        () => _commitTypedGroup(permit),
        zoneValues: {_groupZone: true},
      );
      completer.complete();
    } on Object {
      _historyFaulted = true;
      completer.complete();
      rethrow;
    } finally {
      _groupPublication = null;
    }
  }

  /// Reads a non-content consumed-key receipt outside purgeable note history.
  Future<Map<String, dynamic>?> typedProposalReceipt(String key) async {
    await _ensureIndexed();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const FormatException('Invalid typed receipt key');
    }
    final file = File('${_historyDir.path}/typed-receipts/$key.json');
    return file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : null;
  }

  /// Journals proposal state and its retry receipt before acknowledging either.
  Future<void> writeTypedProposalRecord(
    ProposalRecord record, {
    required String key,
    required String payloadDigest,
    int? expectedRecordRevision,
  }) async {
    await _ensureIndexed();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(payloadDigest) ||
        record.state != 'pending') {
      throw const FormatException('Invalid typed proposal journal');
    }
    await withProposalMutation(record.noteId, () async {
      final intent = File('${_historyDir.path}/typed-intents/$key.json');
      await _atomicText(
        intent,
        jsonEncode({
          'record': record.toStoredJson(),
          'expected_record_revision': expectedRecordRevision,
          'key': key,
          'receipt': {
            'payload_digest': payloadDigest,
            'note_id': record.noteId,
            'proposal_id': record.id,
            'proposal_revision': record.proposalRevision,
          },
        }),
      );
      try {
        await _applyTypedProposalIntent(
          jsonDecode(await intent.readAsString()) as Map<String, dynamic>,
        );
        await intent.delete();
      } on Object {
        _historyFaulted = true;
        rethrow;
      }
    });
  }

  /// Optional typed integrity checks shared by ordinary accepted writes.
  Future<void> Function(StoredNote? next, String id, {required bool reviewed})?
      validateKnowledgeMutation;

  String _serializeNote(StoredNote note) => serializeFrontmatter(
        Frontmatter(metadata: _buildMetadataMap(note), body: note.content),
      );

  Future<void> _atomicText(File file, String text) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> _commitHistory(
    StoredNote note,
    String? path, {
    bool deleted = false,
    bool captureCurrent = false,
    String? actor,
    MarkdownBlockMap? reviewedBlockMap,
    ProposalRecord? acceptedProposal,
    Map<String, dynamic>? acceptedProvenance,
    Map<String, dynamic>? acceptedPolicyDelta,
    int? restoredVersion,
  }) async {
    if (!captureCurrent) {
      await validateKnowledgeMutation?.call(
        deleted ? null : note,
        note.id,
        reviewed: acceptedProposal != null,
      );
    }
    final history = _noteHistory(note.id);
    final oldPath = _relPathById[note.id];
    final previousVersion = note.version - (deleted ? 0 : 1);
    final previousFile = File('${history.path}/$previousVersion.json');
    MarkdownBlockMap? previousMap;
    String? previousSource;
    if (previousFile.existsSync()) {
      final previous =
          jsonDecode(await previousFile.readAsString()) as Map<String, dynamic>;
      final rawMap = previous['block_map'];
      if (rawMap is Map<String, dynamic>) {
        previousMap = MarkdownBlockMap.fromJson(rawMap);
        previousSource = previous['deleted'] == true
            ? ''
            : parseFrontmatter(previous['markdown'] as String).body;
      }
    }
    if (oldPath != null && _fileForRelative(oldPath).existsSync()) {
      previousSource =
          parseFrontmatter(await _fileForRelative(oldPath).readAsString()).body;
    }
    final blockMap = reviewedBlockMap ??
        _blockReconciler.reconcile(
          deleted ? '' : note.content,
          version: note.version + (deleted ? 1 : 0),
          previous: previousMap,
          previousSource: previousSource,
        );
    final invalidated = <Map<String, dynamic>>[];
    final changed = {
      ...blockMap.changedIds,
      ...blockMap.retiredIds,
      ...blockMap.ambiguousIds,
    };
    for (final record in await proposalRecords(noteId: note.id)) {
      if (record.id == acceptedProposal?.id) continue;
      final operations = record.current.candidate['operations'] as List? ?? [];
      final overlaps = operations.any((raw) {
        final operation = raw as Map;
        return operation['type'] == 'delete_note' ||
            changed.contains(operation['block_id']);
      });
      if (deleted || (oldPath != null && oldPath != path) || overlaps) {
        final next = record.invalidate(
          reason: deleted ? 'note_deleted' : 'accepted_target_changed',
          at: _clock.nowUtc(),
        );
        if (!identical(next, record)) invalidated.add(next.toStoredJson());
      }
    }
    if (acceptedProposal != null) {
      invalidated.add(acceptedProposal.toStoredJson());
    }
    final provenance = acceptedProvenance ??
        await readAcceptedProvenance(note.id, version: previousVersion);
    if (restoredVersion != null) {
      provenance.clear();
      final restoredFile = File('${history.path}/$restoredVersion.json');
      final restored = jsonDecode(await restoredFile.readAsString()) as Map;
      final rawMap = restored['block_map'];
      final links =
          (restored['accepted_provenance'] as Map?)?.cast<String, dynamic>() ??
              {};
      if (rawMap is Map<String, dynamic>) {
        final sourceMap = MarkdownBlockMap.fromJson(rawMap);
        for (final block in sourceMap.blocks) {
          final target = blockMap.blocks
              .where(
                (candidate) =>
                    candidate.start == block.start &&
                    candidate.end == block.end &&
                    candidate.kind == block.kind &&
                    candidate.hash == block.hash,
              )
              .firstOrNull;
          final source = links[block.id];
          if (target != null && source is Map<String, dynamic>) {
            provenance[target.id] = {
              ...source,
              'block_revision': target.revision,
            };
          }
        }
      }
    } else if (acceptedProvenance == null) {
      provenance.removeWhere((id, _) => changed.contains(id));
    }
    final event = <String, Object?>{
      'id': note.id,
      if (actor != null) 'actor': actor,
      'version': note.version + (deleted ? 1 : 0),
      'deleted': deleted,
      'recorded_at': _clock.nowUtc().toIso8601String(),
      'markdown': _serializeNote(note),
      'block_map': blockMap.toJson(),
      'accepted_provenance': provenance,
      if (acceptedPolicyDelta != null)
        'accepted_policy_delta': acceptedPolicyDelta,
      if (invalidated.isNotEmpty) 'proposal_updates': invalidated,
      'path': path,
      'previous_path': oldPath,
      if (!captureCurrent &&
          oldPath != null &&
          !File('${history.path}/${note.version - (deleted ? 0 : 1)}.json')
              .existsSync())
        'baseline': await _fileForRelative(oldPath).readAsString(),
    };
    final pending = File('${history.path}/pending.json');
    if (pending.existsSync()) {
      throw StateError('Incomplete history commit requires recovery');
    }
    await _historyDir.create(recursive: true);
    await _atomicText(
      _historyIndexTicket(note.id, note.version + (deleted ? 1 : 0)),
      '',
    );
    await _atomicText(pending, jsonEncode(event));
    try {
      await beforeHistoryApply?.call();
      await _applyHistory(history, event, injectFailure: true);
      await pending.delete();
    } on Object {
      _historyFaulted = true;
      rethrow;
    }
  }

  Future<void> _applyHistory(
    Directory history,
    Map<String, dynamic> event, {
    bool injectFailure = false,
  }) async {
    if (event['accepted_policy_delta'] is Map<String, dynamic>) {
      await ensureRequiredHistory(event['id'] as String);
    }
    final path = event['path'] as String?;
    final oldPath = event['previous_path'] as String?;
    if (path != null) {
      await _atomicText(_fileForRelative(path), event['markdown'] as String);
    }
    if (oldPath != null && oldPath != path) {
      final old = _fileForRelative(oldPath);
      if (old.existsSync()) await old.delete();
    }
    if (injectFailure) await afterHistoryPublish?.call();
    final baseline = event['baseline'] as String?;
    if (baseline != null) {
      final metadata = parseFrontmatter(baseline).metadata;
      final previous = File('${history.path}/${metadata['version']}.json');
      if (!previous.existsSync()) {
        await _atomicText(
          previous,
          jsonEncode({
            'id': metadata['id'],
            'version': metadata['version'],
            'deleted': false,
            'markdown': baseline,
            'recorded_at': event['recorded_at'],
          }),
        );
      }
    }
    final snapshot = File('${history.path}/${event['version']}.json');
    if (!snapshot.existsSync()) {
      await _atomicText(
        snapshot,
        jsonEncode(
          Map.of(event)
            ..remove('baseline')
            ..remove('proposal_updates')
            ..remove('accepted_policy_delta'),
        ),
      );
    }
    final policyDelta = event['accepted_policy_delta'];
    if (policyDelta is Map<String, dynamic>) {
      final replay = acceptedPolicyReplay;
      if (replay == null) {
        throw StateError('Accepted designation replay is not configured');
      }
      await replay(policyDelta);
    }
    for (final raw in event['proposal_updates'] as List? ?? []) {
      final record = ProposalRecord.fromStoredJson(raw as Map<String, dynamic>);
      if (record.noteId != event['id']) {
        throw const FormatException('Journal proposal identity mismatch');
      }
      await _atomicText(
        _proposalFile(record.noteId, record.id),
        jsonEncode(record.toStoredJson()),
      );
    }
  }

  Future<void> _recoverHistory() async {
    if (!_historyDir.existsSync()) return;
    await _recoverTypedProposalIntents();
    await _recoverTypedGroups();
    final entries = await _historyDir.list().toList();
    for (final marker in entries.whereType<File>()) {
      if (!marker.path.endsWith('.purge')) continue;
      final target =
          Directory(marker.path.substring(0, marker.path.length - 6));
      await _applyHistoryPurge(target, await marker.readAsString());
      await marker.delete();
    }
    for (final directory in entries.whereType<Directory>()) {
      if (!directory.existsSync()) continue;
      final pending = File('${directory.path}/pending.json');
      if (!pending.existsSync()) continue;
      final event =
          jsonDecode(await pending.readAsString()) as Map<String, dynamic>;
      await _applyHistory(directory, event);
      await pending.delete();
    }
  }

  /// Retained accepted revisions, oldest first; empty when history disabled.
  Future<List<Map<String, dynamic>>> revisions(String id) async {
    await _ensureIndexed();
    final directory = _noteHistory(id);
    if (!directory.existsSync()) return [];
    final result = <Map<String, dynamic>>[];
    await for (final file in directory.list()) {
      if (file is! File || !RegExp(r'/[0-9]+\.json$').hasMatch(file.path)) {
        continue;
      }
      final event =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      result.add({
        for (final key in const {
          'id',
          'actor',
          'version',
          'deleted',
          'recorded_at',
          'markdown',
          'block_map',
          'path',
          'previous_path',
          'accepted_provenance',
        })
          if (event.containsKey(key)) key: event[key],
      });
    }
    result.sort((a, b) => (a['version'] as int).compareTo(b['version'] as int));
    return result;
  }

  /// Reads the newest accepted revision, including deletion tombstones,
  /// without loading older contents. Returns null when history is absent.
  Future<Map<String, dynamic>?> latestRevision(String id) async {
    await _ensureIndexed();
    final directory = _noteHistory(id);
    if (!directory.existsSync()) return null;
    File? latest;
    var version = -1;
    await for (final entry in directory.list()) {
      if (entry is! File) continue;
      final match = RegExp(r'[\\/]([0-9]+)\.json$').firstMatch(entry.path);
      if (match == null) continue;
      final candidate = int.parse(match[1]!);
      if (candidate > version) {
        version = candidate;
        latest = entry;
      }
    }
    if (latest == null) return null;
    return jsonDecode(await latest.readAsString()) as Map<String, dynamic>;
  }

  /// Reads accepted block metadata without creating or changing identities.
  /// Omitting [version] verifies the current canonical body against its map.
  /// Throws [BlockMapUnavailableException] for legacy or stale metadata.
  Future<MarkdownBlockMap> readBlockMap(String id, {int? version}) =>
      _withLock(id, () async {
        await _ensureIndexed();
        final current = version == null ? await read(id) : null;
        final wanted = version ?? current!.version;
        final snapshot = File('${_noteHistory(id).path}/$wanted.json');
        if (!snapshot.existsSync()) {
          if (current != null) throw const BlockMapUnavailableException();
          throw NoteNotFoundException(id);
        }
        final accepted =
            jsonDecode(await snapshot.readAsString()) as Map<String, dynamic>;
        final raw = accepted['block_map'];
        if (raw is! Map<String, dynamic>) {
          throw const BlockMapUnavailableException();
        }
        final map = MarkdownBlockMap.fromJson(raw);
        final body = current?.content ??
            (accepted['deleted'] == true
                ? ''
                : parseFrontmatter(accepted['markdown'] as String).body);
        if (map.version != wanted || !map.matches(body)) {
          throw const BlockMapUnavailableException(stale: true);
        }
        return map;
      });

  /// Reads retained content; deletion tombstones cannot be restored directly.
  Future<StoredNote> readRevision(String id, int version) async {
    final history = await revisions(id);
    final candidates = history.where(
      (r) => r['version'] == version && r['deleted'] == false,
    );
    if (candidates.isEmpty) throw NoteNotFoundException(id);
    return _toStoredNote(
      parseFrontmatter(candidates.single['markdown'] as String),
      id,
    );
  }

  /// Restores retained content with a new version, including deleted notes.
  /// [ifMatch] must match latest accepted version or deletion tombstone.
  Future<StoredNote> restoreRevision(
    String id,
    int version, {
    required int ifMatch,
    String? actor,
  }) =>
      _withLock(id, () async {
        final history = await revisions(id);
        final candidates = history
            .where((r) => r['version'] == version && r['deleted'] == false);
        if (candidates.isEmpty) throw NoteNotFoundException(id);
        final source = _toStoredNote(
          parseFrontmatter(candidates.single['markdown'] as String),
          id,
        );
        final current = _relPathById.containsKey(id) ? await read(id) : null;
        final latest = current?.version ?? history.last['version'] as int;
        if (latest != ifMatch) {
          throw HistoryVersionConflictException(latest);
        }
        final next = StoredNote(
          id: id,
          title: source.title,
          path: source.path,
          version: latest + 1,
          createdAt: source.createdAt,
          updatedAt: _clock.nowUtc(),
          content: source.content,
          extra: source.extra,
        );
        final path = _relativeFilePath(path: next.path, title: next.title);
        final key = collisionKey(path);
        return _withPathLock(key, () async {
          final owner = _idByKey[key];
          if (owner != null && owner != id) {
            throw PathConflictException(path: next.path, title: next.title);
          }
          await _commitHistory(
            next,
            path,
            actor: actor,
            restoredVersion: version,
          );
          final oldPath = _relPathById[id];
          if (oldPath != null) _idByKey.remove(collisionKey(oldPath));
          _claim(id: id, key: key, relPath: path);
          return next;
        });
      });

  /// Erases retained history and review records permanently. A live note with
  /// server-required history keeps its exact current operational snapshot/map.
  Future<void> purgeHistory(String id) => _withLock(id, () async {
        await _ensureIndexed();
        final directory = _noteHistory(id);
        if (directory.existsSync()) {
          final marker = File('${directory.path}.purge');
          final current = _relPathById.containsKey(id) ? await read(id) : null;
          final keepVersion =
              current != null && _requiredHistoryMarker(id).existsSync()
                  ? current.version
                  : null;
          final intent = jsonEncode({'keep_version': keepVersion});
          await _atomicText(marker, intent);
          try {
            await _applyHistoryPurge(directory, intent);
            await marker.delete();
          } on Object {
            _historyFaulted = true;
            rethrow;
          }
        }
      });

  Future<void> _applyHistoryPurge(Directory directory, String intent) async {
    if (!directory.existsSync()) return;
    final dynamic raw = intent.isEmpty ? null : jsonDecode(intent);
    final keepVersion =
        raw == null ? null : (raw as Map<String, dynamic>)['keep_version'];
    if (keepVersion == null) {
      await directory.delete(recursive: true);
      return;
    }
    if (keepVersion is! int ||
        keepVersion < 1 ||
        !File('${directory.path}/$keepVersion.json').existsSync()) {
      throw StateError('Invalid required-history purge intent');
    }
    final current = File('${directory.path}/$keepVersion.json');
    final snapshot =
        jsonDecode(await current.readAsString()) as Map<String, dynamic>;
    final hasJournalPayload = const {
      'proposal_updates',
      'accepted_policy_delta',
      'baseline',
    }.any(snapshot.containsKey);
    if (hasJournalPayload) {
      snapshot
        ..remove('proposal_updates')
        ..remove('accepted_policy_delta')
        ..remove('baseline');
      await _atomicText(current, jsonEncode(snapshot));
    }
    await for (final entity in directory.list()) {
      if (entity is File &&
          entity.path == '${directory.path}/$keepVersion.json') {
        continue;
      }
      await entity.delete(recursive: true);
    }
  }

  void _claim({
    required NoteId id,
    required String key,
    required String relPath,
  }) {
    _relPathById[id] = relPath;
    _idByKey[key] = id;
  }

  Map<String, Object?> _buildMetadataMap(StoredNote note) {
    // Required keys come first in a stable order; extras follow in their
    // original source order. This matches what Storage round-trips.
    return {
      'id': note.id,
      'title': note.title,
      'path': note.path,
      'version': note.version,
      'created_at': note.createdAt.toIso8601String(),
      'updated_at': note.updatedAt.toIso8601String(),
      ...note.extra,
    };
  }

  /// Computes the relative file path (from [contentDir]) for [path] +
  /// [title], normalizing and sanitizing both.
  String _relativeFilePath({required String path, required String title}) {
    final segments = sanitizedPathSegments(path);
    final base = sanitizedTitleForFilename(title);
    return [...segments, '$base.md'].join('/');
  }

  File _fileForRelative(String relPath) => File('${contentDir.path}/$relPath');

  String _relativePathOf(File file) {
    final root =
        contentDir.path.endsWith('/') ? contentDir.path : '${contentDir.path}/';
    return file.path.startsWith(root)
        ? file.path.substring(root.length)
        : file.path;
  }

  void _assertHistoryHealthy() {
    if (_historyFaulted) {
      throw StateError('Incomplete history commit requires restart');
    }
  }

  Future<T> _withLock<T>(NoteId id, Future<T> Function() body) {
    final lease = Zone.current[_noteTransactionZone];
    if (lease is _NoteTransactionLease && lease.active && lease.id == id) {
      _assertHistoryHealthy();
      return body();
    }
    return _withKeyedLock(_locks, id, () async {
      final lease = _NoteTransactionLease(id);
      try {
        return await runZoned(body, zoneValues: {_noteTransactionZone: lease});
      } finally {
        lease.active = false;
      }
    });
  }

  Future<T> _withPathLock<T>(String key, Future<T> Function() body) =>
      _withKeyedLock(_pathLocks, key, body);

  Future<T> _withKeyedLock<T>(
    Map<String, Future<void>> locks,
    String key,
    Future<T> Function() body,
  ) async {
    final previous = locks[key];
    final completer = Completer<void>();
    locks[key] = completer.future;
    try {
      if (previous != null) {
        try {
          await previous;
        } on Object {
          // Predecessor's failure should not block this turn.
        }
      }
      _assertHistoryHealthy();
      return await body();
    } finally {
      completer.complete();
      if (identical(locks[key], completer.future)) {
        unawaited(Future.value(locks.remove(key)));
      }
    }
  }

  static const Set<String> _reservedKeys = {
    'id',
    'title',
    'path',
    'version',
    'created_at',
    'updated_at',
  };

  // Frontmatter keys a database write interprets structurally rather than
  // as a caller-owned property value. Duplicated locally (rather than
  // imported from `search_index.dart`'s `kServerInterpretedKeys`) to avoid
  // a storage.dart <-> search_index.dart import cycle — `search_index.dart`
  // already imports `storage.dart`. See [_rebuildExtra].
  static const Set<String> _serverInterpretedExtraKeys = {
    'knowledge',
    'type',
    'tags',
    'source',
    'properties',
    'views',
  };

  // Rebuilds `extra` for [update] per the merge rule documented on
  // [update]'s doc comment. Returns [currentExtra] unchanged (same
  // instance) when [properties] is `null`.
  static Map<String, Object?> _rebuildExtra(
    Map<String, Object?> currentExtra,
    Map<String, Object?>? properties,
  ) {
    if (properties == null) return currentExtra;
    final next = <String, Object?>{};
    for (final entry in currentExtra.entries) {
      if (properties.containsKey(entry.key)) {
        next[entry.key] = properties[entry.key];
      } else if (_serverInterpretedExtraKeys.contains(entry.key)) {
        next[entry.key] = entry.value;
      }
    }
    for (final entry in properties.entries) {
      next.putIfAbsent(entry.key, () => entry.value);
    }
    return next;
  }

  static NoteId _ulid() => Ulid().toString();
}

class _NoteTransactionLease {
  _NoteTransactionLease(this.id);
  final String id;
  bool active = true;
}
