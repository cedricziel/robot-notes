import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/note_path.dart';

/// Matches a legacy flat-layout filename: a 26-character Crockford
/// base-32 ULID (uppercase letters and digits) followed by `.md`,
/// directly under the content root.
final RegExp _legacyUlidFilename = RegExp(r'^[0-9A-Z]{26}\.md$');

/// One-time startup step that brings pre-vault-structure note files up
/// to date: a file directly under [contentDir] named `<ulid>.md` whose
/// frontmatter has no `path` key is renamed to `<sanitized-title>.md` at
/// vault root, with `path: ""` added to its frontmatter.
///
/// Candidates are processed in ascending id order (ids are ULIDs, so
/// this is creation order) for determinism. The de-dup check for a
/// colliding target name considers the *entire* current namespace — every
/// file already on disk, migrated or not, and every name already claimed
/// earlier in this same run — not just other files being migrated, so a
/// legacy file can never be written on top of an unrelated note that
/// already happens to occupy the computed (or a de-dup-suffixed) name.
///
/// A file that fails to parse is logged and left untouched; it does not
/// abort the migration for the remaining files, and does not prevent
/// server startup (mirroring the existing "malformed file is logged and
/// skipped" behavior for indexing).
///
/// Returns the number of files migrated.
Future<int> migrateLegacyLayout({
  required Directory contentDir,
  Logger? logger,
}) async {
  final log = logger ?? Logger('legacy_migration');
  if (!contentDir.existsSync()) return 0;

  final entries = contentDir
      .listSync()
      .whereType<File>()
      .where((f) => _legacyUlidFilename.hasMatch(_basename(f.path)))
      .toList();

  // Full current namespace, so a de-dup suffix never collides with a
  // note that isn't itself being migrated (e.g. one already titled
  // "Ideas (2)"). Built once up front; extended as we claim names.
  final taken = <String>{};
  await for (final entity in contentDir.list(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.md')) continue;
    taken.add(collisionKey(_relativeTo(contentDir, entity.path)));
  }

  final candidates = <({File file, String id, String title})>[];
  for (final file in entries) {
    try {
      final fm = parseFrontmatter(file.readAsStringSync());
      if (fm.metadata.containsKey('path')) continue; // already migrated
      final id = fm.metadata['id'];
      final title = fm.metadata['title'];
      if (id is! String || title is! String) {
        log.warning(
          'Skipping legacy migration for ${file.path}: missing id or title',
        );
        continue;
      }
      candidates.add((file: file, id: id, title: title));
    } on FrontmatterFormatException catch (e) {
      log.warning('Skipping legacy migration for ${file.path}: $e');
    }
  }
  candidates.sort((a, b) => a.id.compareTo(b.id));

  var migrated = 0;
  for (final candidate in candidates) {
    try {
      final targetName = _pickTargetName(
        sanitizedTitleForFilename(candidate.title),
        taken,
      );
      final targetRel = '$targetName.md';
      taken.add(collisionKey(targetRel));

      final text = candidate.file.readAsStringSync();
      final fm = parseFrontmatter(text);
      final newMetadata = <String, Object?>{};
      // Insert `path` right after `title` for a stable, readable key
      // order (id, title, path, version, ...), matching how new writes
      // order frontmatter keys.
      for (final entry in fm.metadata.entries) {
        newMetadata[entry.key] = entry.value;
        if (entry.key == 'title') newMetadata['path'] = '';
      }
      newMetadata.putIfAbsent('path', () => '');
      final newText = serializeFrontmatter(
        Frontmatter(metadata: newMetadata, body: fm.body),
      );

      final targetFile = File('${contentDir.path}/$targetRel');
      final targetPath = targetFile.path;
      targetFile.writeAsStringSync(newText);
      if (targetPath != candidate.file.path) {
        candidate.file.deleteSync();
      }
      migrated++;
      log.info(
        'Migrated legacy note ${_basename(candidate.file.path)} to '
        '$targetRel',
      );
    } on Object catch (e) {
      log.warning('Failed to migrate ${candidate.file.path}: $e');
    }
  }

  if (migrated > 0) {
    log.info('Legacy layout migration complete: $migrated file(s) migrated');
  }
  return migrated;
}

/// Returns [baseName] if its key isn't in [taken], otherwise appends
/// ` (2)`, ` (3)`, … until it finds a name whose key is free.
String _pickTargetName(String baseName, Set<String> taken) {
  var candidate = baseName;
  var suffix = 2;
  while (taken.contains(collisionKey('$candidate.md'))) {
    candidate = '$baseName ($suffix)';
    suffix++;
  }
  return candidate;
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _relativeTo(Directory root, String path) {
  final rootPath = root.path.endsWith('/') ? root.path : '${root.path}/';
  return path.startsWith(rootPath) ? path.substring(rootPath.length) : path;
}
