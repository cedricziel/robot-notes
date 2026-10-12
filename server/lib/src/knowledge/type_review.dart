import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:server/src/knowledge/type_document.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/note_path.dart';
import 'package:server/src/oauth/store_support.dart';
import 'package:server/src/proposals/proposal_record.dart';

/// Dedicated definition review using the shared immutable proposal record core.
class KnowledgeTypeReview {
  /// Binds vault-local accepted snapshots and the server clock.
  KnowledgeTypeReview({required this.snapshots, Clock clock = const Clock()})
      : _clock = clock;

  /// Accepted pinned definitions and group publication journal.
  final KnowledgeTypeSnapshots snapshots;
  final Clock _clock;
  NoteAuthorizationService get _authorization => snapshots.authorization;

  KnowledgeTarget _target(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains(r'\') ||
        path.split('/').any(
              (part) => sanitizeFilenameSegment(normalizeToNfc(part)) != part,
            ) ||
        path.split('/').any((part) => part.isEmpty || part.startsWith('.')) ||
        !path.endsWith('.md')) {
      throw const FormatException('Invalid type path');
    }
    final parts = path.split('/');
    return KnowledgeTarget.folder(
      ['types', ...parts.take(parts.length - 1)].join('/'),
    );
  }

  void _require(KnowledgeAction action, Map<String, String> documents) {
    _authorization.require(
      currentKnowledgePrincipal,
      action,
      KnowledgeTarget.folder('types'),
    );
    for (final path in documents.keys) {
      _authorization.require(currentKnowledgePrincipal, action, _target(path));
    }
  }

  ProposalAuthor get _author {
    final principal = currentKnowledgePrincipal;
    return ProposalAuthor(
      principalId: principal.id,
      label: principal.id,
      kind: principal.kind.name,
      agentOrigin: principal.isAgentOrigin,
    );
  }

  String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  Map<String, String> _documents(ProposalRecord record) =>
      (record.versions.last.candidate['documents'] as Map<String, dynamic>)
          .cast<String, String>();

  File _file(String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('Invalid type proposal identity');
    }
    return File('${snapshots.directory.path}/review/$id.json');
  }

  Future<Map<String, dynamic>> _candidate(Map<String, String> documents) async {
    _require(KnowledgeAction.propose, documents);
    if (documents.isEmpty) throw const FormatException('Empty type candidate');
    final existing = {
      for (final definition in await snapshots.definitions())
        definition.reference.key: definition,
    };
    for (final markdown in documents.values) {
      final document = KnowledgeTypeDocument.parse(markdown);
      if (document.definition != null) {
        existing[document.reference.key] = document.definition!;
      }
    }
    final resolver = KnowledgeTypeResolver(existing.values);
    for (final definition in existing.values) {
      resolver.resolve(definition.reference);
    }
    final paths = documents.keys.toList()..sort();
    return {
      'documents': {for (final path in paths) path: documents[path]},
      'generation': await snapshots.generation(),
      'policy': {
        for (final path in paths)
          path: _authorization.store
              .effective(_target(path))
              .fingerprint(_target(path)),
      },
    };
  }

  /// Validates a candidate group without activating definitions.
  Future<void> validate(Map<String, String> documents) async {
    await _candidate(documents);
  }

  /// Retains an idempotent pending candidate under authenticated proposer
  /// identity.
  Future<ProposalRecord> propose(
    Map<String, String> documents, {
    required String idempotencyKey,
  }) =>
      _authorization.store.withMutationLock(() async {
        _require(KnowledgeAction.propose, documents);
        if (idempotencyKey.trim().isEmpty || idempotencyKey.length > 200) {
          throw const FormatException('Invalid type retry key');
        }
        final paths = documents.keys.toList()..sort();
        final inputDigest =
            _digest({for (final path in paths) path: documents[path]});
        final id = _digest([currentKnowledgePrincipal.id, idempotencyKey]);
        final file = _file(id);
        if (file.existsSync()) {
          final retained = await inspect(id);
          if (retained.versions.first.candidate['input_digest'] !=
              inputDigest) {
            throw const ProposalRecordConflictException('idempotency_conflict');
          }
          return retained;
        }
        final candidate = await _candidate(documents);
        candidate['input_digest'] = inputDigest;
        final record = ProposalRecord.create(
          id: id,
          noteId: 'type-definitions',
          author: _author,
          at: _clock.nowUtc(),
          candidate: candidate,
        );
        await atomicWriteJsonFile(file, record.toStoredJson());
        return record;
      });

  /// Inspects retained candidate versions or an atomically published review
  /// outcome.
  Future<ProposalRecord> inspect(String id) async {
    _authorization.require(
      currentKnowledgePrincipal,
      KnowledgeAction.read,
      KnowledgeTarget.folder('types'),
    );
    final accepted = await snapshots.acceptedReview(id);
    final record = accepted ??
        ProposalRecord.fromStoredJson(
          jsonDecode(await _file(id).readAsString()) as Map<String, dynamic>,
        );
    for (final version in record.versions) {
      _require(
        KnowledgeAction.read,
        (version.candidate['documents'] as Map<String, dynamic>)
            .cast<String, String>(),
      );
    }
    return record;
  }

  /// Replaces a pending candidate with CAS while retaining its prior versions.
  Future<ProposalRecord> amend(
    String id,
    Map<String, String> documents, {
    required int expectedRecordRevision,
    required int expectedProposalRevision,
  }) =>
      _authorization.store.withMutationLock(() async {
        final record = await inspect(id);
        _require(KnowledgeAction.propose, _documents(record));
        if (record.author.principalId != currentKnowledgePrincipal.id) {
          _require(KnowledgeAction.review, _documents(record));
        }
        final candidate = await _candidate(documents);
        final amended = record.amend(
          expectedRecordRevision: expectedRecordRevision,
          expectedProposalRevision: expectedProposalRevision,
          author: _author,
          at: _clock.nowUtc(),
          candidate: candidate,
        );
        await atomicWriteJsonFile(_file(id), amended.toStoredJson());
        return amended;
      });

  /// Records non-accepting human review decisions under record CAS.
  Future<ProposalRecord> decide(
    String id, {
    required String decision,
    required int expectedRecordRevision,
  }) =>
      _authorization.store.withMutationLock(() async {
        final record = await inspect(id);
        _require(KnowledgeAction.review, _documents(record));
        final next = record.decide(
          expectedRecordRevision: expectedRecordRevision,
          author: _author,
          decision: decision,
          at: _clock.nowUtc(),
        );
        await atomicWriteJsonFile(_file(id), next.toStoredJson());
        return next;
      });

  /// Human acceptance rechecks policy, generation, constraints, and immutable
  /// pins.
  Future<ProposalRecord> accept(
    String id, {
    required int expectedRecordRevision,
  }) =>
      _authorization.store.withMutationLock(() async {
        final record = await inspect(id);
        final documents = _documents(record);
        _require(KnowledgeAction.review, documents);
        final candidate = record.versions.last.candidate;
        final policy = candidate['policy'] as Map<String, dynamic>;
        for (final path in documents.keys) {
          if (_authorization.store
                  .effective(_target(path))
                  .fingerprint(_target(path)) !=
              policy[path]) {
            throw const ProposalRecordConflictException('policy_changed');
          }
        }
        final generation = candidate['generation'] as int;
        final accepted = record.acceptedForJournal(
          expectedRecordRevision: expectedRecordRevision,
          reviewer: _author,
          at: _clock.nowUtc(),
          noteVersion: generation + 1,
        );
        await snapshots.accept(
          documents,
          expectedGeneration: generation,
          reviewRecord: accepted,
        );
        return accepted;
      });
}
