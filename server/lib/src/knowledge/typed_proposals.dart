import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/canonical_json.dart';
import 'package:server/src/knowledge/source_store.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/storage.dart';
import 'package:ulid/ulid.dart';

String _entryHash(StoredNote note) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          note.id,
          note.title,
          note.path,
          note.version,
          note.content,
          note.extra,
        ]),
      ),
    )
    .toString();

/// One-use publication authority issued only after complete typed-group review.
class TypedKnowledgeAcceptancePermit {
  TypedKnowledgeAcceptancePermit._(
    this._storage,
    this.notes,
    this.record,
    this._bases,
    this.policyDeltas,
  );
  final Storage _storage;
  bool _used = false;
  final Map<String, String> _bases;

  /// Authorized curated designations replayed with the accepted group.
  final Map<String, Map<String, dynamic>> policyDeltas;

  /// Complete reviewed ordinary note revisions, including stable reserved IDs.
  final List<StoredNote> notes;

  /// Final immutable review record committed in the same publication journal.
  final ProposalRecord record;

  /// Rejects reuse or publication through a different vault storage.
  void claim(Storage storage) {
    if (_used || !identical(storage, _storage)) {
      throw StateError('Invalid typed publication permit');
    }
    _used = true;
  }

  /// Verifies the exact accepted baseline checked during human review.
  bool matches(StoredNote note) => _bases[note.id] == _entryHash(note);
}

/// Atomic knowledge candidates, complete-state validation, and human
/// acceptance.
class TypedKnowledgeProposals {
  /// Reuses ordinary notes, retained review records, pinned types, and sources.
  TypedKnowledgeProposals({
    required this.storage,
    required this.types,
    required this.sources,
    required this.authorization,
    required this.onAccepted,
    Clock clock = const Clock(),
  }) : _clock = clock {
    storage.acceptedPolicyReplay ??=
        authorization.store.replayAcceptedNoteDesignation;
    storage.validateKnowledgeMutation ??= _guardMutation;
  }

  /// Canonical accepted Markdown and group journals.
  final Storage storage;

  /// Accepted immutable type definitions.
  final KnowledgeTypeSnapshots types;

  /// Authorized immutable evidence resolution.
  final KnowledgeSourceStore sources;

  /// Shared credential, ACL, and mutation serialization boundary.
  final NoteAuthorizationService authorization;

  /// Derived indexes update only after complete group publication.
  final Future<void> Function(StoredNote note) onAccepted;
  final Clock _clock;

  ProposalAuthor get _author {
    final principal = currentKnowledgePrincipal;
    return ProposalAuthor(
      principalId: principal.id,
      label: principal.id,
      kind: principal.kind.name,
      agentOrigin: principal.isAgentOrigin,
    );
  }

  Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Expected candidate object');
    }
    return value;
  }

  List<Object?> _array(Object? value) {
    if (value is! List<Object?>) {
      throw const FormatException('Expected candidate list');
    }
    return value;
  }

  Future<StoredNote?> _acceptedSnapshot(String id) async {
    final history = await storage.revisions(id);
    if (history.isEmpty || history.last['deleted'] == true) return null;
    final frame = parseFrontmatter(history.last['markdown']! as String);
    final metadata = frame.metadata;
    return StoredNote(
      id: id,
      title: metadata['title']! as String,
      path: metadata['path']! as String,
      version: metadata['version']! as int,
      createdAt: DateTime.parse(metadata['created_at']! as String),
      updatedAt: DateTime.parse(metadata['updated_at']! as String),
      content: frame.body,
      extra: Map<String, Object?>.from(metadata)
        ..removeWhere(
          (key, _) => const {
            'id',
            'title',
            'path',
            'version',
            'created_at',
            'updated_at',
          }.contains(key),
        ),
    );
  }

  String _acceptedState(StoredNote note, {bool includeContent = true}) =>
      canonicalKnowledgeJson({
        'id': note.id,
        'title': note.title,
        'path': note.path,
        'version': note.version,
        'created_at': note.createdAt.toIso8601String(),
        'updated_at': note.updatedAt.toIso8601String(),
        'properties': note.extra,
        if (includeContent) 'content': note.content,
      });

  Future<StoredNote> _read(String id, {bool acceptedOnly = false}) async {
    final note = await storage.read(id);
    authorization.require(
      currentKnowledgePrincipal,
      KnowledgeAction.read,
      KnowledgeTarget.note(note.id, note.path),
    );
    if (acceptedOnly) {
      final accepted = await _acceptedSnapshot(id);
      if (accepted == null &&
          (note.extra['knowledge'] is! Map<String, Object?> ||
              (note.extra['knowledge']! as Map<String, Object?>)['role'] !=
                  'knowledge')) {
        return note;
      }
      if (accepted == null ||
          _acceptedState(note) != _acceptedState(accepted)) {
        throw const ProposalRecordConflictException('accepted_source_changed');
      }
      authorization.requireHistoricalRead(
        currentKnowledgePrincipal,
        id,
        accepted.path,
        note.path,
      );
      return accepted;
    }
    return note;
  }

  Future<
      ({
        List<StoredNote> notes,
        List<Map<String, Object?>> diagnostics,
        Map<String, String> bases,
        Map<String, List<String>> readPaths,
        List<String> readScopes,
      })> _build(
    List<Object?> operations,
    Map<String, String> reserved, {
    KnowledgeAction action = KnowledgeAction.propose,
  }) async {
    if (operations.isEmpty || operations.length > 50) {
      throw const FormatException(
        'Candidate group must contain 1 to 50 operations',
      );
    }
    final result = <StoredNote>[];
    final diagnostics = <Map<String, Object?>>[];
    final bases = <String, String>{};
    final readPaths = <String, List<String>>{};
    final readScopes = <String>{};
    final ids = <String>{};
    final now = _clock.nowUtc();
    for (final indexed in operations.indexed) {
      final operation = _object(indexed.$2);
      if (!operation.keys.every(
        const {
          'kind',
          'local_ref',
          'id',
          'expected_revision',
          'path',
          'title',
          'properties',
          'unset_properties',
          'content',
          'types',
          'relations',
          'evidence',
        }.contains,
      )) {
        throw const FormatException('Unsupported candidate field');
      }
      final kind = operation['kind'];
      StoredNote? previous;
      String id;
      if (kind == 'create') {
        final ref = operation['local_ref'];
        if (ref is! String || ref.isEmpty || !reserved.containsKey(ref)) {
          throw const FormatException('Create requires a unique local_ref');
        }
        id = reserved[ref]!;
      } else if (kind == 'update') {
        previous = await _read(operation['id']! as String, acceptedOnly: true);
        id = previous.id;
        if (operation['expected_revision'] != previous.version) {
          throw const ProposalRecordConflictException(
            'accepted_revision_changed',
          );
        }
        bases[id] = _entryHash(previous);
      } else {
        throw const FormatException('Unsupported typed candidate operation');
      }
      if (!ids.add(id)) {
        throw const FormatException('Duplicate candidate target');
      }
      final path =
          operation['path'] as String? ?? previous?.path ?? 'knowledge';
      final title = operation['title'] as String? ?? previous?.title ?? '';
      authorization.require(
        currentKnowledgePrincipal,
        action,
        KnowledgeTarget.note(id, path),
      );
      if (previous != null) {
        authorization.require(
          currentKnowledgePrincipal,
          action,
          KnowledgeTarget.note(id, previous.path),
        );
      }
      final properties = <String, Object?>{...?previous?.extra};
      final supplied =
          _object(operation['properties'] ?? const <String, Object?>{});
      if (supplied.containsKey('knowledge')) {
        throw const FormatException('Knowledge metadata is server managed');
      }
      properties.addAll(supplied);
      for (final unset
          in _array(operation['unset_properties'] ?? const <Object?>[])) {
        if (unset is! String || unset == 'knowledge') {
          throw const FormatException('Invalid property unset');
        }
        properties.remove(unset);
      }
      if (properties.keys.any(
        const {
          'id',
          'title',
          'path',
          'version',
          'created_at',
          'updated_at',
          'type',
          'source',
          'views',
        }.contains,
      )) {
        throw const FormatException('Reserved typed property');
      }
      final prior = properties['knowledge'] as Map<String, Object?>? ?? {};
      final assigned =
          operation['types'] ?? prior['types'] ?? const <Object?>[];
      final rawRelations = _object(
        operation['relations'] ??
            prior['relations'] ??
            const <String, Object?>{},
      );
      final relations = <String, Object?>{};
      for (final entry in rawRelations.entries) {
        relations[entry.key] = _array(entry.value).map((target) {
          if (target is String) return target;
          final local = _object(target)['local_ref'];
          if (local is! String || !reserved.containsKey(local)) {
            throw const FormatException('Unresolved candidate-local reference');
          }
          return reserved[local]!;
        }).toList();
      }
      properties['knowledge'] = {
        'format_version': 1,
        'role': 'knowledge',
        'types': assigned,
        'relations': relations,
        if (operation.containsKey('evidence') || prior.containsKey('evidence'))
          'evidence': operation['evidence'] ?? prior['evidence'],
      };
      final note = StoredNote(
        id: id,
        title: title,
        path: path,
        version: (previous?.version ?? 0) + 1,
        createdAt: previous?.createdAt ?? now,
        updatedAt: now,
        content: operation['content'] as String? ?? previous?.content ?? '',
        extra: properties,
      );
      result.add(note);
      readPaths[id] = {if (previous != null) previous.path, path}.toList();
      if (title.trim().isEmpty) {
        diagnostics.add(
          {'operation': indexed.$1, 'field': 'title', 'reason': 'required'},
        );
      }
    }
    final resolver = KnowledgeTypeResolver(await types.definitions());
    final group = {for (final note in result) note.id: note};
    for (final indexed in result.indexed) {
      final note = indexed.$2;
      final knowledge = _object(note.extra['knowledge']);
      final assigned = _array(knowledge['types'])
          .map(KnowledgeTypeReference.fromJson)
          .toList();
      if (assigned.isEmpty) {
        diagnostics.add({
          'operation': indexed.$1,
          'field': 'types',
          'reason': 'pinned type required',
        });
      }
      final relations = _object(knowledge['relations']);
      final targets = <String, List<KnowledgeTypeReference>>{};
      for (final values in relations.values) {
        for (final id in _array(values).cast<String>()) {
          final target = group[id] ?? await _read(id, acceptedOnly: true);
          final targetKnowledge = _object(target.extra['knowledge']);
          if (targetKnowledge['role'] != 'knowledge') {
            throw const FormatException('Relation target is not knowledge');
          }
          targets[id] = _array(targetKnowledge['types'])
              .map(KnowledgeTypeReference.fromJson)
              .toList();
        }
      }
      final declaredRelations = <String>{};
      for (final type in assigned) {
        declaredRelations.addAll(resolver.resolve(type).relations.keys);
      }
      for (final name in relations.keys) {
        if (!declaredRelations.contains(name)) {
          diagnostics.add({
            'operation': indexed.$1,
            'field': name,
            'reason': 'undeclared relation',
          });
        }
      }
      for (final type in assigned) {
        final definition = resolver.resolve(type);
        for (final reason in [
          ...definition.validateProperties(note.extra),
          ...resolver.validateRelations(
            type,
            {
              for (final entry in relations.entries)
                if (definition.relations.containsKey(entry.key))
                  entry.key: entry.value,
            },
            targets,
          ),
        ]) {
          diagnostics.add({
            'operation': indexed.$1,
            'type': type.toJson(),
            'reason': reason,
          });
        }
        if (resolver.isSubtype(
          type,
          KnowledgeTypeReference('urn:robot-notes:type:Evidence', 1),
        )) {
          try {
            final evidence = _object(knowledge['evidence']);
            await sources.passage(
              evidence['source_id']! as String,
              evidence['source_revision']! as String,
              _object(evidence['locator']),
            );
            readScopes.add(
              sources
                  .descriptor(
                    evidence['source_id']! as String,
                    evidence['source_revision']! as String,
                  )
                  .scopeId,
            );
          } on Object {
            diagnostics.add({
              'operation': indexed.$1,
              'field': 'evidence',
              'reason': 'source revision or locator unavailable',
            });
          }
        }
      }
    }
    if (diagnostics.isEmpty) {
      await _integrity(result);
    }
    return (
      notes: result,
      diagnostics: diagnostics,
      bases: bases,
      readPaths: readPaths,
      readScopes: readScopes.toList(),
    );
  }

  Future<void> _guardMutation(
    StoredNote? next,
    String id, {
    required bool reviewed,
  }) async {
    final accepted = await _acceptedSnapshot(id);
    if (accepted?.extra['knowledge'] is Map<String, Object?> &&
        (accepted!.extra['knowledge']! as Map<String, Object?>)['role'] ==
            'knowledge') {
      final current = await storage.read(id);
      if (_acceptedState(current, includeContent: !reviewed) !=
          _acceptedState(accepted, includeContent: !reviewed)) {
        throw const ProposalRecordConflictException('accepted_source_changed');
      }
    }
    if (next != null) {
      final knowledge = next.extra['knowledge'];
      if (knowledge is Map<String, Object?> &&
          knowledge['role'] == 'knowledge') {
        final principal = currentKnowledgePrincipal;
        if (!reviewed &&
            (!principal.canActAsHuman ||
                !principal.hasScope('knowledge:edit'))) {
          throw const KnowledgeAccessDeniedException(KnowledgeAction.edit);
        }
        if (knowledge['format_version'] != 1 || next.title.trim().isEmpty) {
          throw const FormatException('Invalid knowledge entry');
        }
        final resolver = KnowledgeTypeResolver(await types.definitions());
        final assigned = _array(knowledge['types'])
            .map(KnowledgeTypeReference.fromJson)
            .toList();
        if (assigned.isEmpty) {
          throw const FormatException('Pinned types required');
        }
        for (final type in assigned) {
          if (resolver
              .resolve(type)
              .validateProperties(next.extra)
              .isNotEmpty) {
            throw const ProposalRecordConflictException(
              'typed_property_invalid',
            );
          }
          if (resolver.isSubtype(
            type,
            KnowledgeTypeReference('urn:robot-notes:type:Evidence', 1),
          )) {
            final evidence = _object(knowledge['evidence']);
            await sources.passage(
              evidence['source_id']! as String,
              evidence['source_revision']! as String,
              _object(evidence['locator']),
            );
          }
        }
      }
    }
    await _integrity(
      [if (next != null) next],
      deleted: next == null ? id : null,
    );
  }

  Future<void> _integrity(List<StoredNote> next, {String? deleted}) async {
    final all = <String, StoredNote>{};
    for (final summary in await storage.list()) {
      final accepted = await _acceptedSnapshot(summary.id);
      if (accepted != null) all[summary.id] = accepted;
    }
    if (deleted != null) all.remove(deleted);
    all.addAll({for (final note in next) note.id: note});
    final typed = all.values
        .where(
          (note) =>
              note.extra['knowledge'] is Map<String, Object?> &&
              (note.extra['knowledge']! as Map<String, Object?>)['role'] ==
                  'knowledge',
        )
        .toList();
    if (typed.isEmpty) return;
    final affected = {
      for (final note in next) note.id,
      if (deleted != null) deleted,
    };
    final relevantNotes = typed.where((note) {
      if (affected.contains(note.id)) return true;
      final relations = _object(
        _object(note.extra['knowledge'])['relations'] ??
            const <String, Object?>{},
      );
      return relations.values
          .any((targets) => _array(targets).any(affected.contains));
    }).toList();
    if (relevantNotes.isEmpty) return;
    final resolver = KnowledgeTypeResolver(await types.definitions());
    final targets = {
      for (final note in typed)
        note.id: _array(_object(note.extra['knowledge'])['types'])
            .map(KnowledgeTypeReference.fromJson)
            .toList(),
    };
    for (final note in relevantNotes) {
      final knowledge = _object(note.extra['knowledge']);
      final relations =
          _object(knowledge['relations'] ?? const <String, Object?>{});
      final assigned = targets[note.id]!;
      for (final type in assigned) {
        final definition = resolver.resolve(type);
        final relevant = {
          for (final entry in relations.entries)
            if (definition.relations.containsKey(entry.key))
              entry.key: entry.value,
        };
        if (resolver.validateRelations(type, relevant, targets).isNotEmpty) {
          throw const ProposalRecordConflictException(
            'relation_integrity_conflict',
          );
        }
      }
    }
  }

  Map<String, String> _reserve(List<Object?> operations) {
    final result = <String, String>{};
    for (final raw in operations) {
      final operation = _object(raw);
      if (operation['kind'] != 'create') continue;
      final ref = operation['local_ref'];
      if (ref is! String || ref.isEmpty || result.containsKey(ref)) {
        throw const FormatException('Duplicate or empty local_ref');
      }
      result[ref] = Ulid().toString().toLowerCase();
    }
    return result;
  }

  Future<void> _authorizeOperations(List<Object?> operations) async {
    for (final raw in operations) {
      final operation = _object(raw);
      final previous = operation['kind'] == 'update'
          ? await _read(operation['id']! as String)
          : null;
      authorization.require(
        currentKnowledgePrincipal,
        KnowledgeAction.propose,
        KnowledgeTarget.folder(
          operation['path'] as String? ?? previous?.path ?? 'knowledge',
        ),
      );
    }
  }

  String _retryHash(String key) => sha256
      .convert(utf8.encode(jsonEncode([currentKnowledgePrincipal.id, key])))
      .toString();

  Future<ProposalRecord?> _retry(String key, String digest) async {
    final receipt = await storage.typedProposalReceipt(key);
    if (receipt == null) return null;
    if (receipt['payload_digest'] != digest) {
      throw const ProposalRecordConflictException('idempotency_conflict');
    }
    try {
      return await inspect(
        receipt['note_id'] as String,
        receipt['proposal_id'] as String,
      );
    } on FileSystemException {
      throw const ProposalRecordConflictException('consumed_retry_key');
    }
  }

  /// Read-only validation returns actionable diagnostics, never accepted
  /// writes.
  Future<Map<String, Object?>> validate(List<Object?> operations) async {
    final built = await _build(operations, _reserve(operations));
    return {
      'valid': built.diagnostics.isEmpty,
      'diagnostics': built.diagnostics,
      'checked_revisions': {
        for (final note in built.notes) note.id: note.version - 1,
      },
    };
  }

  /// Persists incomplete or valid candidates without creating accepted
  /// placeholders.
  Future<ProposalRecord> propose(
    List<Object?> operations, {
    required String idempotencyKey,
    Map<String, Object?> metadata = const {},
    Map<String, List<String>> contextPaths = const {},
    List<String> contextScopes = const [],
  }) =>
      authorization.store.withMutationLock(() async {
        if (idempotencyKey.trim().isEmpty) {
          throw const FormatException('Empty proposal retry key');
        }
        final digest = sha256
            .convert(
              utf8.encode(
                canonicalKnowledgeJson(
                  contextPaths.isEmpty && contextScopes.isEmpty
                      ? metadata.isEmpty
                          ? operations
                          : [operations, metadata]
                      : [operations, metadata, contextPaths, contextScopes],
                ),
              ),
            )
            .toString();
        await _authorizeOperations(operations);
        final key = _retryHash('propose:$idempotencyKey');
        final retry = await _retry(key, digest);
        if (retry != null) return retry;
        for (final record in await storage.proposalRecords()) {
          final candidate = record.versions.first.candidate;
          if (candidate['kind'] != 'typed_knowledge' ||
              record.author.principalId != currentKnowledgePrincipal.id ||
              candidate['retry_key'] != idempotencyKey) {
            continue;
          }
          await inspect(record.noteId, record.id);
          if (candidate['request_digest'] != digest) {
            throw const ProposalRecordConflictException('idempotency_conflict');
          }
          return record;
        }
        final reserved = _reserve(operations);
        final built = await _build(operations, reserved);
        final readPaths = {
          for (final entry in built.readPaths.entries)
            entry.key: entry.value.toSet(),
        };
        for (final entry in contextPaths.entries) {
          for (final path in entry.value) {
            authorization.require(
              currentKnowledgePrincipal,
              KnowledgeAction.read,
              KnowledgeTarget.note(entry.key, path),
            );
            readPaths.putIfAbsent(entry.key, () => {}).add(path);
          }
        }
        for (final scope in contextScopes) {
          sources.scopeSettings(scope);
        }
        final policy = {
          for (final note in built.notes)
            note.id: authorization.store
                .effective(KnowledgeTarget.note(note.id, note.path))
                .fingerprint(KnowledgeTarget.note(note.id, note.path)),
        };
        final record = ProposalRecord.create(
          id: Ulid().toString().toLowerCase(),
          noteId: built.notes.first.id,
          author: _author,
          at: _clock.nowUtc(),
          candidate: {
            'kind': 'typed_knowledge',
            'metadata': metadata,
            'operations': operations,
            'reserved': reserved,
            'diagnostics': built.diagnostics,
            'bases': built.bases,
            'read_paths': {
              for (final entry in readPaths.entries)
                entry.key: entry.value.toList(),
            },
            'read_scopes': {...built.readScopes, ...contextScopes}.toList(),
            'policy': policy,
            'retry_key': idempotencyKey,
            'request_digest': digest,
          },
        );
        await storage.writeTypedProposalRecord(
          record,
          key: key,
          payloadDigest: digest,
        );
        return record;
      });

  /// Inspects candidate history only after checking each historical target
  /// path.
  Future<ProposalRecord> inspect(String noteId, String id) async {
    final record = await storage.readProposalRecord(noteId, id);
    if (record.versions.first.candidate['kind'] != 'typed_knowledge') {
      throw const FormatException('Not a typed knowledge proposal');
    }
    for (final version in record.versions) {
      for (final scope
          in (version.candidate['read_scopes'] as List<dynamic>?) ??
              const <dynamic>[]) {
        sources.scopeSettings(scope as String);
      }
      final paths = version.candidate['read_paths'] as Map<String, dynamic>?;
      if (paths != null) {
        for (final entry in paths.entries) {
          for (final path in (entry.value as List<dynamic>).cast<String>()) {
            authorization.require(
              currentKnowledgePrincipal,
              KnowledgeAction.read,
              KnowledgeTarget.note(entry.key, path),
            );
          }
          try {
            await _read(entry.key);
          } on NoteNotFoundException {
            final history = await storage.revisions(entry.key);
            if (history.isNotEmpty) {
              final frame =
                  parseFrontmatter(history.last['markdown']! as String);
              authorization.require(
                currentKnowledgePrincipal,
                KnowledgeAction.read,
                KnowledgeTarget.note(
                  entry.key,
                  frame.metadata['path']! as String,
                ),
              );
            }
          }
        }
        continue;
      }
      for (final raw in version.candidate['operations'] as List<dynamic>) {
        final operation = _object(raw);
        final target = operation['kind'] == 'update'
            ? await _read(operation['id']! as String)
            : null;
        authorization.require(
          currentKnowledgePrincipal,
          KnowledgeAction.read,
          KnowledgeTarget.folder(
            operation['path'] as String? ?? target?.path ?? 'knowledge',
          ),
        );
      }
    }
    return record;
  }

  /// Replaces a candidate with idempotent CAS while retaining earlier versions.
  Future<ProposalRecord> amend(
    String noteId,
    String id,
    List<Object?> operations, {
    required String idempotencyKey,
    required int expectedRecordRevision,
    required int expectedProposalRevision,
  }) =>
      authorization.store.withMutationLock(() async {
        final record = await inspect(noteId, id);
        if (idempotencyKey.trim().isEmpty) {
          throw const FormatException('Empty amendment key');
        }
        final digest = sha256
            .convert(utf8.encode(canonicalKnowledgeJson(operations)))
            .toString();
        await _authorizeOperations(operations);
        final key = _retryHash('amend:$id:$idempotencyKey');
        final retry = await _retry(key, digest);
        if (retry != null) return retry;
        for (final version in record.versions) {
          if (version.candidate['amendment_key'] == idempotencyKey) {
            if (version.candidate['request_digest'] != digest) {
              throw const ProposalRecordConflictException(
                'idempotency_conflict',
              );
            }
            return record;
          }
        }
        if (record.author.principalId != currentKnowledgePrincipal.id) {
          for (final raw in record.versions.last.candidate['operations']
              as List<dynamic>) {
            final operation = _object(raw);
            final target = operation['kind'] == 'update'
                ? await _read(operation['id']! as String)
                : null;
            authorization.require(
              currentKnowledgePrincipal,
              KnowledgeAction.review,
              KnowledgeTarget.folder(
                operation['path'] as String? ?? target?.path ?? 'knowledge',
              ),
            );
          }
        }
        final previous =
            (record.versions.last.candidate['reserved'] as Map<String, dynamic>)
                .cast<String, String>();
        final reserved = _reserve(operations);
        for (final entry in previous.entries) {
          if (reserved.containsKey(entry.key)) {
            reserved[entry.key] = entry.value;
          }
        }
        final built = await _build(operations, reserved);
        final policy = {
          for (final note in built.notes)
            note.id: authorization.store
                .effective(KnowledgeTarget.note(note.id, note.path))
                .fingerprint(KnowledgeTarget.note(note.id, note.path)),
        };
        final amended = record.amend(
          expectedRecordRevision: expectedRecordRevision,
          expectedProposalRevision: expectedProposalRevision,
          author: _author,
          at: _clock.nowUtc(),
          candidate: {
            'kind': 'typed_knowledge',
            'metadata': record.current.candidate['metadata'],
            'operations': operations,
            'reserved': reserved,
            'diagnostics': built.diagnostics,
            'bases': built.bases,
            'read_paths': built.readPaths,
            'read_scopes': built.readScopes,
            'policy': policy,
            'amendment_key': idempotencyKey,
            'request_digest': digest,
          },
        );
        await storage.writeTypedProposalRecord(
          amended,
          key: key,
          payloadDigest: digest,
          expectedRecordRevision: expectedRecordRevision,
        );
        return amended;
      });

  /// Previews readable entries affected by a proposed type revision without
  /// migration.
  Future<Map<String, Object?>> previewTypeUpgrade(
    KnowledgeTypeDefinition candidate,
  ) async {
    authorization.require(
      currentKnowledgePrincipal,
      KnowledgeAction.propose,
      KnowledgeTarget.folder('types'),
    );
    final accepted = await types.definitions();
    final definitions = {
      for (final definition in accepted) definition.reference.key: definition,
      candidate.reference.key: candidate,
    };
    final resolved =
        KnowledgeTypeResolver(definitions.values).resolve(candidate.reference);
    final affected = <Map<String, Object?>>[];
    for (final summary in await storage.list()) {
      if (!authorization.allows(
        currentKnowledgePrincipal,
        KnowledgeAction.read,
        KnowledgeTarget.note(summary.id, summary.path),
      )) {
        continue;
      }
      final note = await storage.read(summary.id);
      final knowledge = note.extra['knowledge'];
      if (knowledge is! Map<String, Object?> ||
          knowledge['role'] != 'knowledge') {
        continue;
      }
      final assignments = _array(knowledge['types'])
          .map(KnowledgeTypeReference.fromJson)
          .toList();
      if (!assignments.any(
        (type) =>
            type.id == candidate.id && type.key != candidate.reference.key,
      )) {
        continue;
      }
      affected.add({
        'id': note.id,
        'revision': note.version,
        'from_types': assignments.map((type) => type.toJson()).toList(),
        'to_type': candidate.reference.toJson(),
        'diagnostics': resolved.validateProperties(note.extra),
      });
    }
    return {
      'type': candidate.reference.toJson(),
      'affected_entries': affected,
      'accepted_changed': false,
    };
  }

  /// Records a human denial or request for changes without publishing text.
  Future<ProposalRecord> decide(
    String noteId,
    String id, {
    required String decision,
    required int expectedRecordRevision,
  }) =>
      authorization.store.withMutationLock(() async {
        final record = await inspect(noteId, id);
        for (final raw
            in record.current.candidate['operations'] as List<dynamic>) {
          final operation = _object(raw);
          final previous = operation['kind'] == 'update'
              ? await _read(operation['id']! as String)
              : null;
          authorization.require(
            currentKnowledgePrincipal,
            KnowledgeAction.review,
            KnowledgeTarget.folder(
              operation['path'] as String? ?? previous?.path ?? 'knowledge',
            ),
          );
        }
        final next = record.decide(
          expectedRecordRevision: expectedRecordRevision,
          author: _author,
          decision: decision,
          at: _clock.nowUtc(),
        );
        await storage.writeProposalRecord(
          next,
          expectedRecordRevision: expectedRecordRevision,
        );
        return next;
      });

  /// Accepts only a fresh complete candidate with trusted human review
  /// authority.
  Future<ProposalRecord> accept(
    String noteId,
    String id, {
    required int expectedRecordRevision,
  }) =>
      authorization.store.withMutationLock(() async {
        final record = await inspect(noteId, id);
        final candidate = record.versions.last.candidate;
        final operations =
            (candidate['operations'] as List<dynamic>).cast<Object?>();
        final reserved = (candidate['reserved'] as Map<String, dynamic>)
            .cast<String, String>();
        final built =
            await _build(operations, reserved, action: KnowledgeAction.review);
        if (built.diagnostics.isNotEmpty) {
          throw const ProposalRecordConflictException('candidate_invalid');
        }
        final previousBases =
            (candidate['bases'] as Map<String, dynamic>).cast<String, String>();
        if (jsonEncode(previousBases) != jsonEncode(built.bases)) {
          throw const ProposalRecordConflictException(
            'accepted_source_changed',
          );
        }
        for (final note in built.notes) {
          final target = KnowledgeTarget.note(note.id, note.path);
          authorization.require(
            currentKnowledgePrincipal,
            KnowledgeAction.review,
            target,
          );
          if ((candidate['policy'] as Map<String, dynamic>)[note.id] !=
              authorization.store.effective(target).fingerprint(target)) {
            throw const ProposalRecordConflictException('policy_changed');
          }
        }
        final policyDeltas = <String, Map<String, dynamic>>{};
        for (final note in built.notes) {
          final target = KnowledgeTarget.note(note.id, note.path);
          if (!authorization.store.effective(target).curated) {
            authorization.require(
              currentKnowledgePrincipal,
              KnowledgeAction.policy,
              target,
            );
            policyDeltas[note.id] = {
              'id': note.id,
              'path': note.path,
              'approval': 'human',
              'operation_id': 'typed:${record.id}:${note.id}',
            };
          }
        }
        final accepted = record.acceptedForJournal(
          expectedRecordRevision: expectedRecordRevision,
          reviewer: _author,
          at: _clock.nowUtc(),
          noteVersion: built.notes.first.version,
        );
        await storage.acceptTypedKnowledge(
          TypedKnowledgeAcceptancePermit._(
            storage,
            built.notes,
            accepted,
            built.bases,
            policyDeltas,
          ),
        );
        for (final note in built.notes) {
          try {
            await onAccepted(note);
          } catch (_) {
            Logger('knowledge_proposals').warning(
              'Typed acceptance committed; derived index repair pending',
            );
          }
        }
        return accepted;
      });
}
