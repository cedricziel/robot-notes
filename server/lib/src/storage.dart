import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/frontmatter.dart';
import 'package:ulid/ulid.dart';

/// Stable, sortable identifier for a note. Ulids are 26-character
/// Crockford base-32 strings.
typedef NoteId = String;

/// Metadata-only view of a note (no body). Returned by [Storage.list].
@immutable
class NoteSummary {
  /// Creates a summary; consumers do not normally call this directly.
  const NoteSummary({
    required this.id,
    required this.title,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Note identifier (ULID, also the filename stem).
  final NoteId id;

  /// Note title from frontmatter.
  final String title;

  /// Monotonically incremented version. New notes start at `1`.
  final int version;

  /// First write time, in UTC.
  final DateTime createdAt;

  /// Most recent write time, in UTC.
  final DateTime updatedAt;
}

/// Full on-disk view of a note: required metadata + body + any extra
/// frontmatter keys preserved verbatim from the file.
@immutable
class StoredNote {
  /// Creates a stored-note value object.
  const StoredNote({
    required this.id,
    required this.title,
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

  /// Monotonically incremented version.
  final int version;

  /// First write time (UTC).
  final DateTime createdAt;

  /// Most recent write time (UTC).
  final DateTime updatedAt;

  /// Markdown body verbatim.
  final String content;

  /// Frontmatter keys other than the v1 required set (`id`, `title`,
  /// `version`, `created_at`, `updated_at`). Storage round-trips this map
  /// unchanged so external tools can extend the schema without losing
  /// data. Insertion order matches the source file.
  final Map<String, Object?> extra;

  /// Returns a [NoteSummary] derived from this note.
  NoteSummary toSummary() => NoteSummary(
        id: id,
        title: title,
        version: version,
        createdAt: createdAt,
        updatedAt: updatedAt,
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

/// File-backed note store. Owns the `<dataDir>/content/` directory and is
/// the canonical source of truth for note bodies and metadata. Higher
/// layers (notes API, search index, lock manager) call into this class
/// for every read and write.
///
/// Concurrency: every mutating operation on a given id is serialised
/// through a per-id mutex so two updates cannot interleave their tmp +
/// rename sequences. Operations on different ids run concurrently.
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

  /// Filesystem directory holding `*.md` note files.
  final Directory contentDir;

  final Clock _clock;
  final NoteId Function() _idGenerator;
  final Logger _log;
  final Map<NoteId, Future<void>> _locks = {};

  /// Lists every well-formed note in the store as a metadata summary.
  ///
  /// Files that fail to parse (broken YAML, missing required keys) are
  /// logged and skipped; callers SHOULD treat the index as best-effort
  /// and surface the malformed-file warning to operators.
  Future<List<NoteSummary>> list() async {
    if (!contentDir.existsSync()) return const [];
    final entries = <NoteSummary>[];
    await for (final entity in contentDir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.md')) continue;
      try {
        final note = await _readFile(entity);
        entries.add(note.toSummary());
      } on Exception catch (e) {
        _log.warning('Skipping malformed note ${entity.path}: $e');
      }
    }
    entries.sort((a, b) => a.id.compareTo(b.id));
    return entries;
  }

  /// Reads the note with [id], throwing [NoteNotFoundException] if no
  /// such file exists or [FrontmatterFormatException] if the file is
  /// malformed.
  Future<StoredNote> read(NoteId id) async {
    final file = _fileFor(id);
    if (!file.existsSync()) throw NoteNotFoundException(id);
    return _readFile(file);
  }

  /// Creates a new note with the supplied [title] and [content], assigns
  /// it a fresh ULID, stamps `created_at` / `updated_at` from the clock,
  /// and writes it atomically. Returns the stored note (version 1).
  Future<StoredNote> create({
    required String title,
    required String content,
  }) {
    final id = _idGenerator();
    return _withLock(id, () async {
      final now = _clock.nowUtc();
      final note = StoredNote(
        id: id,
        title: title,
        version: 1,
        createdAt: now,
        updatedAt: now,
        content: content,
      );
      await _atomicWrite(note);
      return note;
    });
  }

  /// Updates [id] in place. The supplied [ifMatch] SHALL equal the
  /// on-disk version; otherwise [VersionConflictException] is raised
  /// carrying the current state. Unknown frontmatter keys are preserved.
  Future<StoredNote> update({
    required NoteId id,
    required String title,
    required String content,
    required int ifMatch,
  }) {
    return _withLock(id, () async {
      final current = await read(id);
      if (current.version != ifMatch) {
        throw VersionConflictException(
          current: current,
          suppliedIfMatch: ifMatch,
        );
      }
      final now = _clock.nowUtc();
      final next = StoredNote(
        id: id,
        title: title,
        version: current.version + 1,
        createdAt: current.createdAt,
        updatedAt: now,
        content: content,
        extra: current.extra,
      );
      await _atomicWrite(next);
      return next;
    });
  }

  /// Deletes the file backing [id]. Idempotent: deleting a missing id
  /// throws [NoteNotFoundException].
  Future<void> delete(NoteId id) {
    return _withLock(id, () async {
      final file = _fileFor(id);
      if (!file.existsSync()) throw NoteNotFoundException(id);
      await file.delete();
    });
  }

  Future<StoredNote> _readFile(File file) async {
    final text = await file.readAsString();
    final fm = parseFrontmatter(text);
    return _toStoredNote(fm, file.path);
  }

  StoredNote _toStoredNote(Frontmatter fm, String path) {
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
        'Note $path is missing one of: id, title, version, created_at, '
        'updated_at',
      );
    }
    final extra = <String, Object?>{};
    for (final entry in meta.entries) {
      if (_reservedKeys.contains(entry.key)) continue;
      extra[entry.key] = entry.value;
    }
    return StoredNote(
      id: id,
      title: title,
      version: version,
      createdAt: DateTime.parse(createdRaw).toUtc(),
      updatedAt: DateTime.parse(updatedRaw).toUtc(),
      content: fm.body,
      extra: extra,
    );
  }

  Future<void> _atomicWrite(StoredNote note) async {
    if (!contentDir.existsSync()) {
      await contentDir.create(recursive: true);
    }
    final fm = Frontmatter(
      metadata: _buildMetadataMap(note),
      body: note.content,
    );
    final text = serializeFrontmatter(fm);

    final finalFile = _fileFor(note.id);
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

  Map<String, Object?> _buildMetadataMap(StoredNote note) {
    // Required keys come first in a stable order; extras follow in their
    // original source order. This matches what Storage round-trips.
    return {
      'id': note.id,
      'title': note.title,
      'version': note.version,
      'created_at': note.createdAt.toIso8601String(),
      'updated_at': note.updatedAt.toIso8601String(),
      ...note.extra,
    };
  }

  File _fileFor(NoteId id) => File('${contentDir.path}/$id.md');

  Future<T> _withLock<T>(NoteId id, Future<T> Function() body) async {
    final previous = _locks[id];
    final completer = Completer<void>();
    _locks[id] = completer.future;
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
      if (identical(_locks[id], completer.future)) {
        unawaited(Future.value(_locks.remove(id)));
      }
    }
  }

  static const Set<String> _reservedKeys = {
    'id',
    'title',
    'version',
    'created_at',
    'updated_at',
  };

  static NoteId _ulid() => Ulid().toString();
}
