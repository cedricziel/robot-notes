import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Characters that cannot appear in a filename or folder segment on the
/// filesystems this app targets (Windows reserves the widest set; macOS
/// and Linux are a subset of it, so we sanitize to the common
/// denominator rather than branching per platform).
final RegExp _illegalFilenameChars = RegExp(r'[\\/:*?"<>|]');

/// Normalizes [input] to Unicode NFC.
///
/// Titles and path segments are normalized before they are persisted,
/// compared, or turned into a filename, so that two logically identical
/// strings that arrived pre-composed (NFC) or decomposed (NFD) are never
/// treated as different titles — which matters both for our own
/// collision checks and because filesystems such as APFS may themselves
/// normalize filenames to NFD on write even when the caller sent NFC.
String normalizeToNfc(String input) => unorm.nfc(input);

/// Strips characters that cannot appear in a filename or folder segment
/// (`\ / : * ? " < > |`) from [segment].
///
/// This is applied to a title (producing a filename) and to each `/`-
/// separated component of a `path` (producing folder names) — never to
/// a whole `path` string, which legitimately contains `/` as its
/// separator.
String sanitizeFilenameSegment(String segment) =>
    segment.replaceAll(_illegalFilenameChars, '');

/// Normalizes and sanitizes [title] into the base filename (without the
/// `.md` extension) it should be stored under.
String sanitizedTitleForFilename(String title) =>
    sanitizeFilenameSegment(normalizeToNfc(title));

/// Normalizes and sanitizes a `/`-separated `path` into the folder
/// segments it should be stored under. An empty [path] (vault root)
/// yields an empty list.
List<String> sanitizedPathSegments(String path) {
  if (path.isEmpty) return const [];
  return path
      .split('/')
      .map((segment) => sanitizeFilenameSegment(normalizeToNfc(segment)))
      .toList();
}

/// A comparison key for detecting filesystem-level collisions between two
/// target paths: NFC-normalized and lowercased, so that `Ideas.md` and
/// `ideas.md` (or an NFD/NFC spelling mismatch) are recognized as the
/// same target on the case-insensitive filesystems this app targets
/// (macOS APFS/HFS+, Windows), even though the on-disk name and
/// frontmatter `title` preserve the case and normalization form as
/// written.
String collisionKey(String relativeFilePath) =>
    normalizeToNfc(relativeFilePath).toLowerCase();
