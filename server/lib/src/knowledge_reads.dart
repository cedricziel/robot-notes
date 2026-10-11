import 'dart:convert';
import 'dart:io';

import 'package:server/src/canonical_note_upload.dart';
import 'package:server/src/file_references.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_path.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';

/// Shared read decisions for derived indexes and accepted resources.
class KnowledgeReadService {
  /// Binds reads to the same selected vault and policy as accepted writes.
  KnowledgeReadService({
    required this.authorization,
    required this.metaIndex,
    NoteWriteService? writes,
  }) : _writes = writes;

  /// Selected-vault capability and access rules.
  final NoteAuthorizationService authorization;

  /// Current accepted metadata used to check stale index results.
  final MetaIndex metaIndex;
  final NoteWriteService? _writes;

  /// Source reads require a bound accepted-write service.
  NoteWriteService get writes =>
      _writes ?? (throw StateError('Accepted storage is not bound'));

  /// Uses current accepted paths rather than trusting stale search metadata.
  bool canReadId(String id) {
    final summary = metaIndex.get(id);
    return summary != null && canReadSummary(summary);
  }

  /// Checks accepted note metadata against current access rules.
  bool canReadSummary(NoteSummary summary) => authorization.allows(
        currentKnowledgePrincipal,
        KnowledgeAction.read,
        KnowledgeTarget.note(summary.id, summary.path),
      );

  /// Checks a folder before disclosing its contents.
  bool canReadFolder(String path) => authorization.allows(
        currentKnowledgePrincipal,
        KnowledgeAction.read,
        KnowledgeTarget.folder(path),
      );

  /// Null avoids unnecessary SQL filtering for the configured operator.
  Set<String>? get allowedIds =>
      currentKnowledgePrincipal.kind == KnowledgePrincipalKind.operator
          ? null
          : {
              for (final summary in metaIndex.all)
                if (canReadSummary(summary)) summary.id,
            };

  /// Raw files require physical folder access and any accepted note identity.
  Future<void> requireFile(String relativePath) async {
    if (relativePath.split('/').any(
          (segment) => segment.startsWith('.') || segment.endsWith('.tmp'),
        )) {
      throw const KnowledgeAccessDeniedException(KnowledgeAction.read);
    }
    final folder = relativePath.contains('/')
        ? relativePath.substring(0, relativePath.lastIndexOf('/'))
        : '';
    authorization.require(
      currentKnowledgePrincipal,
      KnowledgeAction.read,
      KnowledgeTarget.folder(folder),
    );
    final file = File('${writes.storage.contentDir.path}/$relativePath');
    if (!file.existsSync()) return;
    if (await isCanonicalNotePayload(file)) {
      final bytes = <int>[];
      await for (final chunk in file.openRead(0, 65536)) {
        bytes.addAll(chunk);
      }
      final parsed = parseFrontmatter(utf8.decode(bytes, allowMalformed: true));
      final id = parsed.metadata['id'];
      if (id is! String) {
        throw const KnowledgeAccessDeniedException(KnowledgeAction.read);
      }
      await requireNote(id);
      authorization.require(
        currentKnowledgePrincipal,
        KnowledgeAction.read,
        KnowledgeTarget.note(id, folder),
      );
    }
    // Accepted links carry their note's access rules to referenced files.
    for (final summary in metaIndex.all.toList()) {
      final StoredNote note;
      try {
        note = await writes.storage.read(summary.id);
      } on NoteNotFoundException {
        continue;
      }
      if (vaultFileReferences(note.content, note.path)
          .any((path) => collisionKey(path) == collisionKey(relativePath))) {
        authorization.require(
          currentKnowledgePrincipal,
          KnowledgeAction.read,
          KnowledgeTarget.note(note.id, note.path),
        );
      }
    }
  }

  /// Resolves a server-owned current note or deletion tombstone target.
  Future<KnowledgeTarget> resolveTarget(String id) =>
      writes.knowledgeTarget(id);

  /// Resolves the current note or tombstone before checking read access.
  Future<void> requireNote(String id) async => authorization.require(
        currentKnowledgePrincipal,
        KnowledgeAction.read,
        await resolveTarget(id),
      );
}
