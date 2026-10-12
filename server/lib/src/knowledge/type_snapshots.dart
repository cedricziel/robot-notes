import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:server/src/knowledge/type_document.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/note_path.dart';
import 'package:server/src/oauth/store_support.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:ulid/ulid.dart';

/// Canonical accepted type snapshots with an atomic group generation.
class KnowledgeTypeSnapshots {
  /// Uses vault-local storage and the shared mutation and authorization
  /// boundary.
  KnowledgeTypeSnapshots({
    required this.directory,
    required this.authorization,
    Clock clock = const Clock(),
  }) : _clock = clock;

  /// Vault-local root; never supplied by an agent.
  final Directory directory;

  /// Trusted credentials and effective filesystem policy.
  final NoteAuthorizationService authorization;
  final Clock _clock;

  File get _manifest => File('${directory.path}/accepted.json');
  File get _publication => File('${directory.path}/publication.json');

  Future<void> _publishDocuments(Map<String, dynamic> documents) async {
    for (final entry in documents.entries) {
      final file = File('${directory.path}/types/${_safePath(entry.key)}');
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(entry.value as String, flush: true);
      await temporary.rename(file.path);
    }
  }

  Future<void> _recoverPublication(int generation) async {
    if (!_publication.existsSync()) return;
    final journal =
        jsonDecode(await _publication.readAsString()) as Map<String, dynamic>;
    if (journal['generation'] == generation) {
      await _publishDocuments(journal['documents'] as Map<String, dynamic>);
    }
    await _publication.delete();
  }

  void _require(KnowledgeAction action, [String path = '']) {
    final parts = path.split('/');
    final folder =
        parts.length == 1 ? '' : parts.sublist(0, parts.length - 1).join('/');
    authorization.require(
      currentKnowledgePrincipal,
      action,
      KnowledgeTarget.folder(folder.isEmpty ? 'types' : 'types/$folder'),
    );
  }

  Future<Map<String, dynamic>> _readManifest() =>
      authorization.store.withMutationLock(_loadManifest);

  Future<Map<String, dynamic>> _loadManifest() async {
    if (!_manifest.existsSync()) {
      await _recoverPublication(0);
      return {'generation': 0, 'entries': <String, dynamic>{}};
    }
    final value =
        jsonDecode(await _manifest.readAsString()) as Map<String, dynamic>;
    if (value['generation'] is! int ||
        value['entries'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid type snapshot manifest');
    }
    await _recoverPublication(value['generation'] as int);
    return value;
  }

  String _safePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains(r'\') ||
        path.contains('//') ||
        path.split('/').any(
              (part) => sanitizeFilenameSegment(normalizeToNfc(part)) != part,
            ) ||
        path.split('/').any((part) => part.startsWith('.')) ||
        !path.endsWith('.md')) {
      throw const FormatException('Invalid type document path');
    }
    return path;
  }

  Future<String> _snapshot(String digest) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid snapshot digest');
    }
    final markdown =
        await File('${directory.path}/snapshots/$digest.md').readAsString();
    if (sha256.convert(utf8.encode(markdown)).toString() != digest) {
      throw const FormatException('Type snapshot digest mismatch');
    }
    return markdown;
  }

  /// Retains original ontology bytes outside ordinary note indexes.
  Future<String> retainArtifact(List<int> bytes) async {
    _require(KnowledgeAction.propose);
    final digest = sha256.convert(bytes).toString();
    final file = File('${directory.path}/artifacts/$digest.bin');
    if (!file.existsSync()) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    } else if (sha256.convert(await file.readAsBytes()).toString() != digest) {
      throw const FormatException('Ontology artifact digest mismatch');
    }
    return digest;
  }

  /// Current accepted group generation used by proposal freshness checks.
  Future<int> generation() async {
    _require(KnowledgeAction.read);
    return (await _readManifest())['generation'] as int;
  }

  /// Loads a review outcome committed atomically with its accepted snapshots.
  Future<ProposalRecord?> acceptedReview(String id) async {
    _require(KnowledgeAction.read);
    final records =
        (await _readManifest())['reviews'] as Map<String, dynamic>? ?? {};
    final record = records[id] as Map<String, dynamic>?;
    return record == null ? null : ProposalRecord.fromStoredJson(record);
  }

  /// Loads only accepted snapshots, never externally edited live documents.
  Future<List<KnowledgeTypeDefinition>> definitions() async {
    _require(KnowledgeAction.read);
    final manifest = await _readManifest();
    final result = <KnowledgeTypeDefinition>[];
    for (final entry in (manifest['entries'] as Map<String, dynamic>).values) {
      final record = entry as Map<String, dynamic>;
      _require(KnowledgeAction.read, record['path'] as String);
      final document = KnowledgeTypeDocument.parse(
        await _snapshot(record['digest'] as String),
      );
      if (document.definition != null) result.add(document.definition!);
    }
    return result;
  }

  String _publishDocument(
    String candidate,
    String path,
    String noteId,
    int version,
    DateTime createdAt,
  ) {
    final frontmatter = parseFrontmatter(candidate);
    final metadata = Map<String, Object?>.from(frontmatter.metadata);
    metadata.addAll({
      'id': noteId,
      'title': metadata['title'] ??
          KnowledgeTypeDocument.parse(candidate)
              .reference
              .id
              .split(RegExp('[/:#]'))
              .last,
      'path': ['types', ...path.split('/').take(path.split('/').length - 1)]
          .join('/'),
      'version': version,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': _clock.nowUtc().toIso8601String(),
    });
    return serializeFrontmatter(
      Frontmatter(metadata: metadata, body: frontmatter.body),
    );
  }

  /// Publishes validated snapshots atomically under trusted human review
  /// authority.
  /// Stale generations and changed bytes for an existing pinned version fail.
  Future<int> accept(
    Map<String, String> documents, {
    required int expectedGeneration,
    ProposalRecord? reviewRecord,
  }) =>
      authorization.store.withMutationLock(() async {
        _require(KnowledgeAction.review);
        if (reviewRecord != null &&
            (reviewRecord.state != 'accepted' ||
                reviewRecord.acceptedVersion != expectedGeneration + 1)) {
          throw const FormatException('Invalid type review journal outcome');
        }
        if (documents.isEmpty) throw const FormatException('Empty type group');
        final manifest = await _readManifest();
        if (manifest['generation'] != expectedGeneration) {
          throw StateError('Type generation changed');
        }
        final entries = Map<String, dynamic>.from(
          manifest['entries'] as Map<String, dynamic>,
        );
        final accepted = <String, KnowledgeTypeDefinition>{};
        for (final entry in entries.entries) {
          final record = entry.value as Map<String, dynamic>;
          _require(KnowledgeAction.read, record['path'] as String);
          final document = KnowledgeTypeDocument.parse(
            await _snapshot(record['digest'] as String),
          );
          if (document.reference.key != entry.key) {
            throw const FormatException('Type snapshot identity mismatch');
          }
          if (document.definition != null) {
            accepted[entry.key] = document.definition!;
          }
        }
        final pending = <String, String>{};
        final publishedDocuments = <String, String>{};
        for (final entry in documents.entries) {
          final path = _safePath(entry.key);
          _require(KnowledgeAction.review, path);
          final document = KnowledgeTypeDocument.parse(entry.value);
          final key = document.reference.key;
          final candidateDigest =
              sha256.convert(utf8.encode(entry.value)).toString();
          final previous = entries[key] as Map<String, dynamic>?;
          if (previous != null &&
              previous['candidate_digest'] != candidateDigest) {
            throw const FormatException('Pinned definition is immutable');
          }
          if (pending.containsKey(key)) {
            throw const FormatException('Duplicate type in group');
          }
          String published;
          if (previous != null) {
            published = await _snapshot(previous['digest'] as String);
          } else {
            final prior = entries.values
                .cast<Map<String, dynamic>>()
                .where((entry) => entry['identity'] == document.reference.id)
                .toList();
            final priorMetadata = prior.isEmpty
                ? null
                : parseFrontmatter(
                    await _snapshot(prior.last['digest'] as String),
                  ).metadata;
            published = _publishDocument(
              entry.value,
              path,
              priorMetadata?['id'] as String? ??
                  Ulid().toString().toLowerCase(),
              (priorMetadata?['version'] as int? ?? 0) + 1,
              priorMetadata == null
                  ? _clock.nowUtc()
                  : DateTime.parse(priorMetadata['created_at']! as String),
            );
          }
          final digest = sha256.convert(utf8.encode(published)).toString();
          entries[key] = {
            'path': path,
            'digest': digest,
            'candidate_digest': candidateDigest,
            'identity': document.reference.id,
          };
          if (document.definition != null) accepted[key] = document.definition!;
          pending[key] = published;
          publishedDocuments[path] = published;
        }
        for (final markdown in documents.values) {
          final document = KnowledgeTypeDocument.parse(markdown);
          if (document.role != 'ontology_adoption') continue;
          final adoption = (parseFrontmatter(markdown).metadata['knowledge']!
              as Map<String, Object?>)['adoption']! as Map<String, Object?>;
          final digest = adoption['sha256']! as String;
          final artifact = File('${directory.path}/artifacts/$digest.bin');
          if (!artifact.existsSync() ||
              sha256.convert(await artifact.readAsBytes()).toString() !=
                  digest) {
            throw const FormatException(
              'Retained adoption artifact unavailable',
            );
          }
          for (final ref in adoption['definitions']! as List<Object?>) {
            if (!entries
                .containsKey(KnowledgeTypeReference.fromJson(ref).key)) {
              throw const FormatException('Incomplete adoption membership');
            }
          }
          final dispositions =
              adoption['unsupported_dispositions']! as Map<String, Object?>;
          if (!dispositions.values
              .every((value) => value == 'preserve_as_guidance')) {
            throw const FormatException(
              'Unsupported semantics need explicit disposition',
            );
          }
        }
        final resolver = KnowledgeTypeResolver(accepted.values);
        for (final definition in accepted.values) {
          resolver.resolve(definition.reference);
        }
        for (final entry in pending.entries) {
          final record = entries[entry.key] as Map<String, dynamic>;
          final file =
              File('${directory.path}/snapshots/${record['digest']}.md');
          if (!file.existsSync()) {
            await file.parent.create(recursive: true);
            await file.writeAsString(entry.value, flush: true);
          } else {
            await _snapshot(record['digest'] as String);
          }
        }
        final generation = expectedGeneration + 1;
        await atomicWriteJsonFile(_publication, {
          'generation': generation,
          'documents': publishedDocuments,
        });
        await atomicWriteJsonFile(
          _manifest,
          {
            'generation': generation,
            'entries': entries,
            'reviews': {
              ...?manifest['reviews'] as Map<String, dynamic>?,
              if (reviewRecord != null)
                reviewRecord.id: reviewRecord.toStoredJson(),
            },
          },
        );
        await _recoverPublication(generation);
        return generation;
      });

  /// Reports live files changed since review without activating their contents.
  Future<List<String>> externalCandidates() async {
    _require(KnowledgeAction.read);
    final manifest = await _readManifest();
    final latest = <String, String>{};
    for (final entry in (manifest['entries'] as Map<String, dynamic>).values) {
      final record = entry as Map<String, dynamic>;
      latest[_safePath(record['path'] as String)] = record['digest'] as String;
    }
    final result = <String>[];
    for (final entry in latest.entries) {
      _require(KnowledgeAction.read, entry.key);
      final file = File('${directory.path}/types/${entry.key}');
      if (!file.existsSync() ||
          sha256.convert(await file.readAsBytes()).toString() != entry.value) {
        result.add(entry.key);
      }
    }
    return result;
  }

  /// Exports portable accepted documents, manifests, and original ontology
  /// bytes.
  Future<Map<String, List<int>>> exportBundle() =>
      authorization.store.withMutationLock(() async {
        final markdown = await export();
        final result = {
          for (final entry in markdown.entries)
            entry.key: utf8.encode(entry.value),
        };
        final manifest = await _readManifest();
        result['accepted.json'] = utf8.encode(
          jsonEncode({
            'generation': manifest['generation'],
            'entries': manifest['entries'],
          }),
        );
        for (final value in markdown.values) {
          final document = KnowledgeTypeDocument.parse(value);
          if (document.role != 'ontology_adoption') continue;
          final adoption = (parseFrontmatter(value).metadata['knowledge']!
              as Map<String, Object?>)['adoption']! as Map<String, Object?>;
          final digest = adoption['sha256']! as String;
          final bytes = await File('${directory.path}/artifacts/$digest.bin')
              .readAsBytes();
          if (sha256.convert(bytes).toString() != digest) {
            throw const FormatException('Export artifact digest mismatch');
          }
          result['artifacts/$digest.bin'] = bytes;
        }
        return result;
      });

  /// Exports every accepted pinned revision without reading unreviewed live
  /// files.
  Future<Map<String, String>> export() async {
    _require(KnowledgeAction.read);
    final manifest = await _readManifest();
    final result = <String, String>{};
    for (final entry in (manifest['entries'] as Map<String, dynamic>).values) {
      final record = entry as Map<String, dynamic>;
      _require(KnowledgeAction.read, record['path'] as String);
      final digest = record['digest'] as String;
      result['snapshots/$digest.md'] = await _snapshot(digest);
    }
    return result;
  }
}
