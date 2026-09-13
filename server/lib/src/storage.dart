import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/excerpt.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/note_path.dart';
import 'package:server/src/tags.dart';
import 'package:ulid/ulid.dart';

export 'package:server/src/note_path.dart' show InvalidPathException;

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
  })  : _clock = clock,
        _idGenerator = idGenerator ?? _ulid,
        _log = logger ?? Logger('storage');

  /// Filesystem directory holding `*.md` note files (recursively, under
  /// per-note folders).
  final Directory contentDir;

  final Clock _clock;
  final NoteId Function() _idGenerator;
  final Logger _log;

  // Per-id write serialization (unchanged from before path support).
  final Map<NoteId, Future<void>> _locks = {};

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

  Future<void>? _indexBuild;

  /// Folder paths currently known to hold an empty-folder marker (see
  /// [kFolderMarkerFilename]). A path may appear here and also have notes
  /// in it — the marker is not removed once notes exist alongside it.
  Set<String> get emptyFolderPaths => Set.unmodifiable(_emptyFolderPaths);

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
  Future<StoredNote> create({
    required String title,
    required String content,
    String path = '',
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
      );
      await _writeAtNewLocation(note, relPath);
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
  Future<StoredNote> update({
    required NoteId id,
    required String title,
    required String content,
    required int ifMatch,
    String? path,
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
          extra: current.extra,
        );
        if (newRelPath == oldRelPath) {
          await _writeAtNewLocation(next, newRelPath);
        } else {
          await _writeAtNewLocation(next, newRelPath);
          final oldFile = _fileForRelative(oldRelPath);
          if (oldFile.existsSync()) await oldFile.delete();
          _idByKey.remove(oldKey);
        }
        _claim(id: id, key: newKey, relPath: newRelPath);
        return next;
      });
    });
  }

  /// Deletes the file backing [id]. Idempotent: deleting a missing id
  /// throws [NoteNotFoundException].
  Future<void> delete(NoteId id) {
    return _withLock(id, () async {
      final file = await _locate(id);
      await file.delete();
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
  Future<void> _ensureIndexed() {
    if (_relPathById.isNotEmpty || _indexBuild != null) {
      return _indexBuild ?? Future.value();
    }
    final build = _scanAll();
    _indexBuild = build.then((_) {});
    return _indexBuild!;
  }

  Future<List<StoredNote>> _scanAll() async {
    _relPathById.clear();
    _idByKey.clear();
    _emptyFolderPaths.clear();
    final notes = <StoredNote>[];
    if (!contentDir.existsSync()) return notes;
    await for (final entity in contentDir.list(recursive: true)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('/$kFolderMarkerFilename')) {
        _emptyFolderPaths.add(_folderOf(_relativePathOf(entity)));
        continue;
      }
      if (!entity.path.endsWith('.md')) continue;
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
  Future<void> _writeAtNewLocation(StoredNote note, String relPath) async {
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

  Future<T> _withLock<T>(NoteId id, Future<T> Function() body) =>
      _withKeyedLock(_locks, id, body);

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

  static NoteId _ulid() => Ulid().toString();
}
