import 'dart:convert';
import 'dart:io';
import 'package:server/src/frontmatter.dart';

/// A raw upload cannot publish a canonical accepted note without its journal.
class CanonicalNoteUploadException implements Exception {
  /// Signals that raw publication would bypass the accepted-note journal.
  const CanonicalNoteUploadException();
}

/// Inspects bounded frontmatter independently of the filename.
/// Oversized or malformed frontmatter is rejected conservatively.
Future<bool> isCanonicalNotePayload(File file) async {
  const maxHeaderBytes = 65536;
  final bytes = <int>[];
  await for (final chunk in file.openRead(0, maxHeaderBytes + 1)) {
    bytes.addAll(chunk);
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  if (!text.startsWith('---\n') && !text.startsWith('---\r\n')) return false;
  final end =
      RegExp(r'^---\r?$', multiLine: true).allMatches(text).skip(1).firstOrNull;
  if (end == null) return true;
  try {
    final parsed = parseFrontmatter(
      "${text.substring(0, end.end).replaceAll('\r\n', '\n')}\n",
    );
    final metadata = parsed.metadata;
    return const {'id', 'title', 'version', 'created_at', 'updated_at'}
        .every(metadata.containsKey);
  } on Object {
    return true;
  }
}
