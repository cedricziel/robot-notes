import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:mime/mime.dart';
import 'package:server/src/note_path.dart';

export 'package:server/src/note_path.dart' show InvalidPathException;

/// Result of a successful [AttachmentStore.write].
@immutable
class AttachmentWriteResult {
  /// Creates an attachment write result.
  const AttachmentWriteResult({
    required this.path,
    required this.filename,
    required this.size,
    required this.contentType,
  });

  /// Folder the attachment was written to, `/`-separated, no
  /// leading/trailing slash. Empty string means the vault root.
  final String path;

  /// Sanitized filename the attachment was stored under.
  final String filename;

  /// Size of the written file, in bytes.
  final int size;

  /// Content-type resolved for the upload (declared by the caller, or
  /// guessed from the filename's extension).
  final String contentType;
}

/// Thrown by [AttachmentStore.write] when the sanitized target
/// `<path>/<filename>` already refers to an existing file or directory —
/// a note, another attachment, an empty-folder marker, or a subfolder.
@immutable
class AttachmentCollisionException implements Exception {
  /// Creates a collision naming the [path]/[filename] that collided.
  const AttachmentCollisionException({
    required this.path,
    required this.filename,
  });

  /// The folder the upload targeted.
  final String path;

  /// The sanitized filename that collided.
  final String filename;

  @override
  String toString() => 'AttachmentCollisionException: $path/$filename';
}

/// Thrown by [AttachmentStore.write] when the byte stream exceeds
/// [maxBytes] before finishing. No partial file is left at the target
/// path.
@immutable
class AttachmentTooLargeException implements Exception {
  /// Creates an exception naming the [maxBytes] limit that was exceeded.
  const AttachmentTooLargeException({required this.maxBytes});

  /// The configured maximum upload size, in bytes.
  final int maxBytes;

  @override
  String toString() => 'AttachmentTooLargeException: exceeds $maxBytes bytes';
}

/// Writes uploaded, non-note files into the same folder structure notes
/// live in, reusing the identical path/filename sanitization and
/// case/NFC-insensitive collision rules a note's path/title already go
/// through (see `note_path.dart`) — but through its own small write path
/// rather than `Storage`'s note-oriented `create`/`update` API, since an
/// attachment has no frontmatter, id, or version and is never indexed.
///
/// Both `POST /notes/attachments` and the `upload_file` MCP tool call
/// this same store so the sanitization/collision/atomicity invariants
/// only need to be correct in one place.
class AttachmentStore {
  /// Creates a store rooted at [contentDir] — the same directory
  /// `Storage` writes note files into.
  AttachmentStore({required this.contentDir});

  /// Filesystem directory shared with `Storage`'s note files.
  final Directory contentDir;

  // Per-target-path write serialization, keyed by `collisionKey` of the
  // relative file path a write is about to claim — the same pattern
  // `Storage` uses for note create/rename races, so two writers racing
  // to the same new attachment path can't both pass the collision check
  // before either writes.
  final Map<String, Future<void>> _pathLocks = {};

  /// Writes [bytes] to `<path>/<filename>` (sanitized the same way a
  /// note's path/title are), streaming rather than buffering so a
  /// request never needs to be fully held in memory before the size
  /// limit can reject it.
  ///
  /// Throws [InvalidPathException] if [path] or [filename] sanitizes to
  /// nothing usable, [AttachmentCollisionException] if the target
  /// already exists, and [AttachmentTooLargeException] if [bytes]
  /// exceeds [maxBytes] — in the last case, no partial file is left on
  /// disk.
  Future<AttachmentWriteResult> write({
    required String path,
    required String filename,
    required Stream<List<int>> bytes,
    required int maxBytes,
    String? contentType,
  }) async {
    final segments = sanitizedPathSegments(path);
    final sanitizedFilename = sanitizeFilenameSegment(normalizeToNfc(filename));
    if (sanitizedFilename.isEmpty) {
      throw InvalidPathException(path: filename, segment: sanitizedFilename);
    }
    final relDir = segments.join('/');
    final relFile =
        relDir.isEmpty ? sanitizedFilename : '$relDir/$sanitizedFilename';
    final key = collisionKey(relFile);

    return _withPathLock(key, () async {
      final dir =
          relDir.isEmpty ? contentDir : Directory('${contentDir.path}/$relDir');
      if (dir.existsSync()) {
        final targetKey = collisionKey(sanitizedFilename);
        for (final entity in dir.listSync()) {
          if (collisionKey(_basename(entity.path)) == targetKey) {
            throw AttachmentCollisionException(
              path: relDir,
              filename: sanitizedFilename,
            );
          }
        }
      } else {
        await dir.create(recursive: true);
      }

      final finalFile = File('${dir.path}/$sanitizedFilename');
      final tmp = File('${finalFile.path}.tmp');
      final sink = tmp.openWrite();
      var total = 0;
      var tooLarge = false;
      try {
        await for (final chunk in bytes) {
          total += chunk.length;
          if (total > maxBytes) {
            tooLarge = true;
            break;
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (tooLarge) {
        if (tmp.existsSync()) await tmp.delete();
        throw AttachmentTooLargeException(maxBytes: maxBytes);
      }
      await tmp.rename(finalFile.path);

      final resolvedContentType = contentType ??
          lookupMimeType(sanitizedFilename) ??
          'application/octet-stream';
      return AttachmentWriteResult(
        path: relDir,
        filename: sanitizedFilename,
        size: total,
        contentType: resolvedContentType,
      );
    });
  }

  String _basename(String relOrAbsolutePath) {
    final idx = relOrAbsolutePath.lastIndexOf('/');
    return idx < 0 ? relOrAbsolutePath : relOrAbsolutePath.substring(idx + 1);
  }

  Future<T> _withPathLock<T>(String key, Future<T> Function() body) async {
    final previous = _pathLocks[key];
    final completer = Completer<void>();
    _pathLocks[key] = completer.future;
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
      if (identical(_pathLocks[key], completer.future)) {
        unawaited(Future.value(_pathLocks.remove(key)));
      }
    }
  }
}
