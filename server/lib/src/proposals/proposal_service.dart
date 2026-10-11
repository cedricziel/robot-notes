import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/markdown_blocks.dart';
import 'package:server/src/note_path.dart';
import 'package:server/src/proposals/block_compiler.dart';
import 'package:server/src/proposals/evidence_reference.dart';
import 'package:server/src/proposals/proposal_operation.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/storage.dart';
import 'package:ulid/ulid.dart';

part 'proposal_acceptance.dart';

String _hash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// Missing or expired referenced evidence cannot be used for acceptance.
class ProposalEvidenceException implements Exception {
  /// Records a machine-readable resolver failure without exposing payload.
  const ProposalEvidenceException(this.reason);

  /// Evidence check that failed.
  final String reason;
}

/// Pending knowledge, explicit inspection, and authorized atomic human review.
class ProposalService {
  /// Uses trusted request context and the shared policy and note locks.
  ProposalService({
    required this.storage,
    required this.authorization,
    required this.onAccepted,
    this.archiveReader,
    this.validateDraft,
    Clock clock = const Clock(),
    String Function()? idGenerator,
    ProposalBlockCompiler? compiler,
  })  : _clock = clock,
        _idGenerator = idGenerator ?? (() => Ulid().toString().toLowerCase()),
        _compiler = compiler ?? ProposalBlockCompiler();

  /// Canonical source and retained review journal in the selected vault.
  final Storage storage;

  /// Central capabilities, role, resource ACL, and mutation serialization.
  final NoteAuthorizationService authorization;

  /// Updates derived views after committed publication; failures leave tickets.
  final Future<void> Function(
    StoredNote note,
    String actor, {
    required bool deleted,
  }) onAccepted;

  /// Reads an explicitly authorized archive digest in this selected vault.
  final Future<Map<String, dynamic>?> Function(String digest)? archiveReader;

  /// Validates draft properties against the current database registry.
  final void Function(StoredNote note)? validateDraft;
  final Clock _clock;
  final String Function() _idGenerator;
  final ProposalBlockCompiler _compiler;

  ProposalAuthor _author(String? actor) {
    final principal = currentKnowledgePrincipal;
    return ProposalAuthor(
      principalId: principal.id,
      label: actor ?? principal.id,
      kind: principal.kind.name,
    );
  }

  KnowledgeTarget _target(StoredNote note) =>
      KnowledgeTarget.note(note.id, note.path);

  /// Submits precise changes without publishing accepted content.
  Future<ProposalRecord> submit(
    String id,
    Map<String, dynamic> input, {
    String? actor,
  }) =>
      authorization.store.withMutationLock(
        () => storage.withProposalMutation(id, () async {
          final note = await storage.read(id);
          authorization.require(
            currentKnowledgePrincipal,
            KnowledgeAction.propose,
            _target(note),
          );
          _fields(input, const {
            'base_version',
            'operations',
            'evidence_refs',
            'idempotency_key',
          });
          final key = _key(input);
          final retry = await _retry(id, key, input);
          if (retry != null) return retry;
          final candidate = await _candidate(note, input);
          candidate.addAll(_retryContext(key, input));
          final record = ProposalRecord.create(
            id: _idGenerator(),
            noteId: id,
            author: _author(actor),
            at: _clock.nowUtc(),
            candidate: candidate,
          );
          await storage.writeProposalRecord(record);
          return _maybeAcceptAutomatically(record, _target(note), actor);
        }),
      );

  /// Reserves a draft identity; no accepted placeholder or Markdown is created.
  Future<ProposalRecord> submitNew(
    Map<String, dynamic> input, {
    String? actor,
  }) =>
      authorization.store.withMutationLock(() async {
        await storage.prepareHistory();
        _fields(input, const {
          'path',
          'title',
          'content',
          'properties',
          'evidence_refs',
          'idempotency_key',
          'curated_intent',
        });
        final path = sanitizedPathSegments(_string(input, 'path', empty: true))
            .join('/');
        final target = KnowledgeTarget.folder(path);
        authorization.require(
          currentKnowledgePrincipal,
          KnowledgeAction.propose,
          target,
        );
        final key = _key(input);
        final retry = await _retry(null, key, input);
        if (retry != null) return retry;
        final title = _string(input, 'title');
        sanitizedTitleForFilename(title);
        final content = _string(input, 'content', empty: true);
        final properties = _properties(input['properties']);
        final refs = _refs(input['evidence_refs']);
        final resolved = await _resolve(refs);
        final id = _idGenerator();
        final map = MarkdownBlockReconciler().reconcile(content, version: 1);
        final permissions =
            authorization.permissions(currentKnowledgePrincipal, target);
        if (input['curated_intent'] != null &&
            input['curated_intent'] is! bool) {
          throw const FormatException('curated_intent must be boolean');
        }
        final record = ProposalRecord.create(
          id: _idGenerator(),
          noteId: id,
          author: _author(actor),
          at: _clock.nowUtc(),
          candidate: {
            'new_note': true,
            'title': title,
            'path': path,
            'draft': {
              'title': title,
              'path': path,
              'content': content,
              'properties': properties,
              'curated_intent': input['curated_intent'] ?? true,
            },
            'base_version': 0,
            'operations': <Object?>[],
            'evidence_refs': [for (final ref in refs) ref.toJson()],
            'evidence_resolution': resolved,
            'policy_revision': permissions['policy_revision'],
            'policy_fingerprint': permissions['policy_fingerprint'],
            'preview_map': map.toJson(),
            ..._retryContext(key, input),
          },
        );
        await storage.writeProposalRecord(record);
        return record;
      });

  Future<Map<String, dynamic>> _candidate(
    StoredNote note,
    Map<String, dynamic> input,
  ) async {
    if (input['base_version'] != note.version) {
      throw const ProposalRecordConflictException('accepted_base_changed');
    }
    final operations = ProposalOperation.parseAll(input['operations']);
    final refs = _refs(input['evidence_refs']);
    final allRefs = [
      ...refs,
      for (final op in operations) ...op.evidenceRefs,
      for (final op in operations) ...op.supersedes,
    ];
    final resolved = await _resolve(allRefs);
    final map = await storage.readBlockMap(note.id);
    final gaps = _compiler.captureGaps(note.content, map, operations);
    final compiled = _compiler.compile(
      note.content,
      map,
      operations,
      baseVersion: note.version,
      gaps: gaps,
    );
    final permissions =
        authorization.permissions(currentKnowledgePrincipal, _target(note));
    return {
      'new_note': false,
      'title': note.title,
      'path': note.path,
      'base_version': note.version,
      'operations': [for (final op in operations) op.toJson()],
      'evidence_refs': [for (final ref in refs) ref.toJson()],
      'evidence_resolution': resolved,
      'policy_revision': permissions['policy_revision'],
      'policy_fingerprint': permissions['policy_fingerprint'],
      'insertion_gaps': {
        for (final entry in gaps.entries) '${entry.key}': entry.value.toJson(),
      },
      'introduced_identities': compiled.introducedIdentities,
      'base_map': map.toJson(),
      'preview_map': compiled.blockMap.toJson(),
      'preview_content': compiled.content,
    };
  }

  Map<String, dynamic> _retryContext(String key, Map<String, dynamic> input) =>
      {
        '_idempotency_key': key,
        '_request_hash': _hash(input),
        '_proposer_id': currentKnowledgePrincipal.id,
      };

  Future<ProposalRecord?> _retry(
    String? id,
    String key,
    Map<String, dynamic> input,
  ) async {
    for (final record in await storage.proposalRecords(noteId: id)) {
      final candidate = record.versions.first.candidate;
      if (candidate['_idempotency_key'] != key ||
          candidate['_proposer_id'] != currentKnowledgePrincipal.id ||
          (id == null && candidate['new_note'] != true)) {
        continue;
      }
      if (candidate['_request_hash'] != _hash(input)) {
        throw const ProposalRecordConflictException('idempotency_key_reused');
      }
      return record;
    }
    return null;
  }

  /// Retains an amendment and previous candidate under both CAS generations.
  Future<ProposalRecord> amend(
    String id,
    String proposalId,
    Map<String, dynamic> input, {
    String? actor,
  }) =>
      authorization.store.withMutationLock(
        () => storage.withProposalMutation(id, () async {
          final record = await storage.readProposalRecord(id, proposalId);
          final target = await _recordTarget(record);
          authorization.require(
            currentKnowledgePrincipal,
            KnowledgeAction.propose,
            target,
          );
          final draft = record.current.candidate['new_note'] == true;
          _fields(
            input,
            draft
                ? const {
                    'proposal_revision',
                    'record_revision',
                    'path',
                    'title',
                    'content',
                    'properties',
                    'evidence_refs',
                    'curated_intent',
                  }
                : const {
                    'proposal_revision',
                    'record_revision',
                    'base_version',
                    'operations',
                    'evidence_refs',
                  },
          );
          final candidate = draft
              ? await _amendedDraft(record, input)
              : await _candidate(await storage.read(id), input);
          final updated = record.amend(
            expectedRecordRevision: _revision(input, 'record_revision'),
            expectedProposalRevision: _revision(input, 'proposal_revision'),
            author: _author(actor),
            at: _clock.nowUtc(),
            candidate: candidate,
          );
          await storage.writeProposalRecord(
            updated,
            expectedRecordRevision: record.recordRevision,
          );
          return draft
              ? updated
              : _maybeAcceptAutomatically(
                  updated,
                  await _recordTarget(updated),
                  actor,
                );
        }),
      );

  Future<Map<String, dynamic>> _amendedDraft(
    ProposalRecord record,
    Map<String, dynamic> input,
  ) async {
    final previous = record.current.candidate;
    final path =
        sanitizedPathSegments(_string(input, 'path', empty: true)).join('/');
    final target = KnowledgeTarget.folder(path);
    authorization.require(
      currentKnowledgePrincipal,
      KnowledgeAction.propose,
      target,
    );
    final title = _string(input, 'title');
    sanitizedTitleForFilename(title);
    final content = _string(input, 'content', empty: true);
    final refs = _refs(input['evidence_refs']);
    final resolution = await _resolve(refs);
    final properties = _properties(input['properties']);
    if (input['curated_intent'] != null && input['curated_intent'] is! bool) {
      throw const FormatException('curated_intent must be boolean');
    }
    final map = MarkdownBlockReconciler().reconcile(
      content,
      version: 1,
      previous: MarkdownBlockMap.fromJson(
        previous['preview_map'] as Map<String, dynamic>,
      ),
      previousSource: (previous['draft'] as Map)['content'] as String,
    );
    final permissions =
        authorization.permissions(currentKnowledgePrincipal, target);
    return {
      'new_note': true,
      'path': path,
      'title': title,
      'draft': {
        'path': path,
        'title': title,
        'content': content,
        'properties': properties,
        'curated_intent': input['curated_intent'] ?? true,
      },
      'base_version': 0,
      'operations': <Object?>[],
      'evidence_refs': [for (final ref in refs) ref.toJson()],
      'evidence_resolution': resolution,
      'preview_map': map.toJson(),
      'policy_revision': permissions['policy_revision'],
      'policy_fingerprint': permissions['policy_fingerprint'],
    };
  }

  Future<KnowledgeTarget> _recordTarget(ProposalRecord record) async {
    final candidate = record.current.candidate;
    if (candidate['new_note'] == true && record.state != 'accepted') {
      return KnowledgeTarget.folder(candidate['path'] as String);
    }
    try {
      return _target(await storage.read(record.noteId));
    } on NoteNotFoundException {
      final revisions = await storage.revisions(record.noteId);
      if (revisions.isEmpty) throw NoteNotFoundException(record.noteId);
      final last = parseFrontmatter(revisions.last['markdown'] as String);
      return KnowledgeTarget.note(
        record.noteId,
        (last.metadata['path'] as String?) ?? '',
      );
    }
  }

  bool _policyCurrent(ProposalRecord record, KnowledgeTarget target) {
    final candidate = record.current.candidate;
    final permissions =
        authorization.permissions(currentKnowledgePrincipal, target);
    return candidate['policy_revision'] == permissions['policy_revision'] &&
        candidate['policy_fingerprint'] == permissions['policy_fingerprint'];
  }

  /// Inspects only proposals whose server-resolved target the caller can read.
  Future<Map<String, dynamic>> inspect(String id, String proposalId) =>
      authorization.store.withMutationLock(
        () => storage.withProposalMutation(id, () async {
          var record = await storage.readProposalRecord(id, proposalId);
          final target = await _recordTarget(record);
          authorization.require(
            currentKnowledgePrincipal,
            KnowledgeAction.read,
            target,
          );
          record = await _refresh(record, target);
          final detail = record.inspect()
            ..removeWhere(
              (key, value) =>
                  key.startsWith('_') ||
                  const {
                    'insertion_gaps',
                    'introduced_identities',
                    'evidence_resolution',
                  }.contains(key),
            )
            ..['allowed_actions'] = _actions(record, target);
          final preview = MarkdownBlockMap.fromJson(
            record.current.candidate['preview_map'] as Map<String, dynamic>,
          );
          MarkdownBlockMap? accepted;
          try {
            accepted = await storage.readBlockMap(id);
          } on NoteNotFoundException {
            // Deleted notes and unaccepted drafts retain their comment history.
          } on BlockMapUnavailableException {
            // External edits cannot manufacture a current comment anchor.
          }
          detail['comments'] = [
            for (final comment in record.comments)
              {
                ...comment,
                'anchor_status': comment['anchor_kind'] == 'proposed'
                    ? (const {'needs_re_review', 'conflicted'}
                                .contains(record.state) ||
                            comment['proposal_revision'] !=
                                record.proposalRevision
                        ? 'stale'
                        : _anchorStatus(comment, preview.blocks))
                    : _anchorStatus(comment, accepted?.blocks ?? []),
              },
          ];
          return detail;
        }),
      );

  Future<ProposalRecord> _refresh(
    ProposalRecord record,
    KnowledgeTarget target,
  ) async {
    if (!const {'pending', 'changes_requested'}.contains(record.state)) {
      return record;
    }
    String? reason;
    var conflicted = false;
    if (!_policyCurrent(record, target)) {
      reason = 'policy_changed';
    } else if (record.current.candidate['new_note'] != true) {
      try {
        final note = await storage.read(record.noteId);
        final map = await storage.readBlockMap(record.noteId);
        final candidate = record.current.candidate;
        _compiler.compile(
          note.content,
          map,
          ProposalOperation.parseAll(candidate['operations']),
          baseVersion: candidate['base_version'] as int,
          gaps: {
            for (final entry in (candidate['insertion_gaps'] as Map).entries)
              int.parse(entry.key as String): ProposalInsertionGap.fromJson(
                entry.value as Map<String, dynamic>,
              ),
          },
          introducedIdentities: (candidate['introduced_identities'] as Map)
              .cast<String, String>(),
        );
      } on ProposalBlockConflictException catch (error) {
        reason = error.reason;
        conflicted = true;
      } on BlockMapUnavailableException {
        reason = 'accepted_block_map_unavailable';
        conflicted = true;
      } on NoteNotFoundException {
        reason = 'note_deleted';
        conflicted = true;
      }
    }
    if (reason == null) return record;
    final next = record.invalidate(
      reason: reason,
      at: _clock.nowUtc(),
      conflicted: conflicted,
    );
    await storage.writeProposalRecord(
      next,
      expectedRecordRevision: record.recordRevision,
    );
    return next;
  }

  List<String> _actions(ProposalRecord record, KnowledgeTarget target) {
    final principal = currentKnowledgePrincipal;
    final terminal = const {'accepted', 'denied'}.contains(record.state);
    final propose =
        authorization.allows(principal, KnowledgeAction.propose, target);
    final review =
        authorization.allows(principal, KnowledgeAction.review, target);
    final candidate = record.current.candidate;
    final needsDesignation = candidate['new_note'] == true &&
        (candidate['draft'] as Map)['curated_intent'] == true &&
        !authorization.store.effective(target).curated;
    return [
      'read',
      if (propose || review) 'comment',
      if (!terminal && propose) 'amend',
      if (!terminal && review) ...['deny', 'request_changes'],
      if (review &&
          const {'pending', 'changes_requested'}.contains(record.state) &&
          _policyCurrent(record, target) &&
          (!needsDesignation ||
              authorization.allows(principal, KnowledgeAction.policy, target)))
        'approve',
    ];
  }

  /// Lists authorized review summaries, including server-reserved drafts.
  Future<List<Map<String, dynamic>>> list({
    String? noteId,
    bool includeTerminal = false,
    String? state,
  }) =>
      authorization.store.withMutationLock(() async {
        if (state != null &&
            !const {
              'pending',
              'changes_requested',
              'needs_re_review',
              'conflicted',
              'accepted',
              'denied',
            }.contains(state)) {
          throw const FormatException('Invalid proposal state filter');
        }
        final items = <Map<String, dynamic>>[];
        for (final record in await storage.proposalRecords(noteId: noteId)) {
          if ((state != null && record.state != state) ||
              (state == null &&
                  !includeTerminal &&
                  const {'accepted', 'denied'}.contains(record.state))) {
            continue;
          }
          final target = await _recordTarget(record);
          if (!authorization.allows(
            currentKnowledgePrincipal,
            KnowledgeAction.read,
            target,
          )) {
            continue;
          }
          final candidate = record.current.candidate;
          items.add({
            ...record.summary(),
            'title': candidate['title'],
            'path': target.path,
            'new_note': candidate['new_note'] == true,
          });
        }
        return items;
      });

  /// Comments require read plus propose or trusted human review permission.
  Future<ProposalRecord> comment(
    String id,
    String proposalId,
    Map<String, dynamic> input, {
    String? actor,
  }) =>
      authorization.store.withMutationLock(
        () => storage.withProposalMutation(id, () async {
          final record = await storage.readProposalRecord(id, proposalId);
          final target = await _recordTarget(record);
          authorization.require(
            currentKnowledgePrincipal,
            KnowledgeAction.read,
            target,
          );
          final actions = _actions(record, target);
          if (!actions.contains('comment')) {
            throw const KnowledgeAccessDeniedException(
              KnowledgeAction.propose,
            );
          }
          _fields(input, const {
            'record_revision',
            'body',
            'block_id',
            'block_revision',
            'reply_to',
          });
          _commentInput(input);
          final blockId = input['block_id'] as String?;
          final blockRevision = input['block_revision'] as int?;
          final baseRaw = record.current.candidate['base_map'];
          final base = baseRaw is Map<String, dynamic>
              ? MarkdownBlockMap.fromJson(baseRaw)
              : null;
          final acceptedAnchor = base?.blocks.any(
                (block) =>
                    block.id == blockId && block.revision == blockRevision,
              ) ??
              false;
          if (blockId != null) {
            final preview = MarkdownBlockMap.fromJson(
              record.current.candidate['preview_map'] as Map<String, dynamic>,
            );
            if (![...preview.blocks, ...?base?.blocks].any(
              (b) => b.id == blockId && b.revision == blockRevision,
            )) {
              throw const ProposalRecordConflictException(
                'comment_anchor_changed',
              );
            }
          }
          final updated = record.comment(
            expectedRecordRevision: _revision(input, 'record_revision'),
            author: _author(actor),
            body: _string(input, 'body'),
            at: _clock.nowUtc(),
            commentId: _idGenerator(),
            blockId: blockId,
            blockRevision: blockRevision,
            replyTo: input['reply_to'] as String?,
            noteVersion: acceptedAnchor
                ? record.current.candidate['base_version'] as int?
                : (record.current.candidate['preview_map'] as Map)['version']
                    as int,
            anchorKind: acceptedAnchor ? 'accepted' : 'proposed',
          );
          await storage.writeProposalRecord(
            updated,
            expectedRecordRevision: record.recordRevision,
          );
          return updated;
        }),
      );

  /// Reads accepted-block threads without wrapping them in a fake proposal.
  Future<Map<String, dynamic>> acceptedComments(String id) =>
      authorization.store.withMutationLock(
        () => storage.withProposalMutation(id, () async {
          MarkdownBlockMap? map;
          KnowledgeTarget target;
          try {
            final note = await storage.read(id);
            target = _target(note);
            authorization.require(
              currentKnowledgePrincipal,
              KnowledgeAction.read,
              target,
            );
            map = await storage.readBlockMap(id);
          } on NoteNotFoundException {
            final history = await storage.revisions(id);
            if (history.isEmpty) throw NoteNotFoundException(id);
            final metadata =
                parseFrontmatter(history.last['markdown'] as String).metadata;
            target =
                KnowledgeTarget.note(id, metadata['path'] as String? ?? '');
            authorization.require(
              currentKnowledgePrincipal,
              KnowledgeAction.read,
              target,
            );
            map = await storage.readBlockMap(
              id,
              version: history.last['version'] as int,
            );
          }
          final stored = await storage.readBlockComments(id);
          return {
            ...stored,
            'items': [
              for (final comment in stored['items'] as List)
                {
                  ...comment as Map<String, dynamic>,
                  'anchor_status': _anchorStatus(comment, map.blocks),
                },
            ],
          };
        }),
      );

  /// Appends accepted-block comments with exact anchor and record CAS.
  Future<Map<String, dynamic>> commentAccepted(
    String id,
    Map<String, dynamic> input, {
    String? actor,
  }) =>
      authorization.store.withMutationLock(
        () => storage.withProposalMutation(id, () async {
          final note = await storage.read(id);
          final target = _target(note);
          final principal = currentKnowledgePrincipal;
          authorization.require(principal, KnowledgeAction.read, target);
          if (!authorization.allows(
                principal,
                KnowledgeAction.propose,
                target,
              ) &&
              !authorization.allows(
                principal,
                KnowledgeAction.review,
                target,
              )) {
            throw const KnowledgeAccessDeniedException(KnowledgeAction.propose);
          }
          _fields(input, const {
            'record_revision',
            'body',
            'block_id',
            'block_revision',
            'reply_to',
          });
          final generation = input['record_revision'];
          if (generation is! int || generation < 0) {
            throw const FormatException('Invalid comments generation');
          }
          final stored = await storage.readBlockComments(id);
          if (stored['record_revision'] != generation) {
            throw const ProposalRecordConflictException('comments_changed');
          }
          final items = (stored['items'] as List).cast<Map<String, dynamic>>();
          _commentInput(input);
          final replyTo = input['reply_to'] as String?;
          Map<String, dynamic>? parent;
          if (replyTo != null) {
            parent = items
                .where((comment) => comment['comment_id'] == replyTo)
                .firstOrNull;
            if (parent == null) {
              throw const FormatException('Comment thread not found');
            }
          }
          final blockId = input['block_id'] ?? parent?['block_id'];
          final revision = input['block_revision'] ?? parent?['block_revision'];
          if (blockId is! String || revision is! int || revision < 1) {
            throw const FormatException('Accepted block anchor required');
          }
          if (parent != null &&
              (blockId != parent['block_id'] ||
                  revision != parent['block_revision'])) {
            throw const FormatException(
              'Reply cannot change its thread anchor',
            );
          }
          if (parent == null) {
            final map = await storage.readBlockMap(id);
            if (!map.blocks
                .any((b) => b.id == blockId && b.revision == revision)) {
              throw const ProposalRecordConflictException(
                'comment_anchor_changed',
              );
            }
          }
          final author = _author(actor);
          final commentId = _idGenerator();
          final next = {
            'record_revision': generation + 1,
            'items': [
              ...items,
              {
                'comment_id': commentId,
                'thread_id': parent?['thread_id'] ?? commentId,
                'author_label': author.label,
                'author_kind': author.kind,
                'author_principal_id': author.principalId,
                'body': _string(input, 'body'),
                'block_id': blockId,
                'block_revision': revision,
                'note_version': parent?['note_version'] ?? note.version,
                if (replyTo != null) 'reply_to': replyTo,
                'created_at': _clock.nowUtc().toIso8601String(),
              }
            ],
          };
          await storage.writeBlockComments(
            id,
            next,
            expectedRecordRevision: generation,
          );
          return acceptedComments(id);
        }),
      );

  /// Publishes reviewed changes after checking current authorization.
  Future<ProposalRecord> decide(
    String id,
    String proposalId,
    Map<String, dynamic> input, {
    String? actor,
  }) =>
      authorization.store.withMutationLock(
        () => storage.withProposalMutation(id, () async {
          final record = await storage.readProposalRecord(id, proposalId);
          final target = await _recordTarget(record);
          authorization.require(
            currentKnowledgePrincipal,
            KnowledgeAction.review,
            target,
          );
          _fields(input, const {'decision', 'record_revision', 'comment'});
          final revision = _revision(input, 'record_revision');
          if (record.recordRevision != revision) {
            throw const ProposalRecordConflictException('record_changed');
          }
          final decision = _string(input, 'decision');
          if (!const {'approve', 'deny', 'request_changes'}
              .contains(decision)) {
            throw const FormatException('Unsupported decision');
          }
          if (decision != 'approve') {
            var updated = record.decide(
              expectedRecordRevision: revision,
              author: _author(actor),
              decision: decision,
              at: _clock.nowUtc(),
            );
            if (input['comment'] != null) {
              updated = updated.comment(
                expectedRecordRevision: updated.recordRevision,
                author: _author(actor),
                body: _string(input, 'comment'),
                at: _clock.nowUtc(),
                commentId: _idGenerator(),
              );
            }
            await storage.writeProposalRecord(
              updated,
              expectedRecordRevision: record.recordRevision,
            );
            return updated;
          }
          return _accept(record, target, input, actor);
        }),
      );

  Future<ProposalRecord> _maybeAcceptAutomatically(
    ProposalRecord record,
    KnowledgeTarget target,
    String? actor,
  ) async {
    if (authorization.store.effective(target).approval !=
        'evidence_no_conflict') {
      return record;
    }
    final candidate = record.current.candidate;
    final operations = ProposalOperation.parseAll(candidate['operations']);
    final refs = [
      ..._refs(candidate['evidence_refs']),
      for (final operation in operations) ...operation.evidenceRefs,
    ];
    if (operations.isEmpty ||
        operations.any(
          (operation) =>
              operation.type != 'attach_evidence' ||
              operation.evidenceRefs.isEmpty ||
              operation.supersedes.isNotEmpty,
        ) ||
        refs.any((ref) => !ref.requiresResolution)) {
      return record;
    }
    authorization.require(
      currentKnowledgePrincipal,
      KnowledgeAction.propose,
      target,
    );
    await _resolve(refs);
    return _accept(
      record,
      target,
      {'decision': 'approve', 'record_revision': record.recordRevision},
      actor,
      automatic: true,
    );
  }

  Future<ProposalRecord> _accept(
    ProposalRecord record,
    KnowledgeTarget target,
    Map<String, dynamic> input,
    String? actor, {
    bool automatic = false,
  }) async {
    final id = record.noteId;
    final proposalId = record.id;
    final revision = _revision(input, 'record_revision');
    if (!_policyCurrent(record, target)) {
      final invalid = record.invalidate(
        reason: 'policy_changed',
        at: _clock.nowUtc(),
      );
      await storage.writeProposalRecord(
        invalid,
        expectedRecordRevision: record.recordRevision,
      );
      throw const ProposalRecordConflictException('policy_changed');
    }
    final candidate = record.current.candidate;
    final newNote = candidate['new_note'] == true;
    final refs = _refs(candidate['evidence_refs']);
    late StoredNote note;
    late MarkdownBlockMap map;
    var deleted = false;
    var provenance = <String, dynamic>{};
    Map<String, dynamic>? policyDelta;
    if (newNote) {
      final draft = candidate['draft'] as Map<String, dynamic>;
      final content = draft['content'] as String;
      if (draft['curated_intent'] == true &&
          !authorization.store.effective(target).curated) {
        authorization.require(
          currentKnowledgePrincipal,
          KnowledgeAction.policy,
          target,
        );
        policyDelta = {
          'id': id,
          'path': target.path,
          'approval': 'human',
          'operation_id': '$proposalId:${record.proposalRevision}',
        };
        if (storage.acceptedPolicyReplay == null) {
          throw StateError(
            'Accepted designation replay is not configured',
          );
        }
      }
      await _resolve(refs);
      map = MarkdownBlockMap.fromJson(
        candidate['preview_map'] as Map<String, dynamic>,
      );
      final at = _clock.nowUtc();
      note = StoredNote(
        id: id,
        title: draft['title'] as String,
        path: target.path,
        version: 1,
        createdAt: at,
        updatedAt: at,
        content: content,
        extra: _properties(draft['properties']),
      );
      validateDraft?.call(note);
      for (final block in map.blocks) {
        provenance[block.id] = _association(block.revision, refs, const []);
      }
    } else {
      final current = await storage.read(id);
      final currentMap = await storage.readBlockMap(id);
      final operations = ProposalOperation.parseAll(candidate['operations']);
      await _resolve([
        ...refs,
        for (final op in operations) ...op.evidenceRefs,
        for (final op in operations) ...op.supersedes,
      ]);
      CompiledBlockProposal compiled;
      try {
        compiled = _compiler.compile(
          current.content,
          currentMap,
          operations,
          baseVersion: candidate['base_version'] as int,
          gaps: {
            for (final entry in (candidate['insertion_gaps'] as Map).entries)
              int.parse(entry.key as String): ProposalInsertionGap.fromJson(
                entry.value as Map<String, dynamic>,
              ),
          },
          introducedIdentities: (candidate['introduced_identities'] as Map)
              .cast<String, String>(),
        );
      } on ProposalBlockConflictException catch (error) {
        final invalid = record.invalidate(
          reason: error.reason,
          at: _clock.nowUtc(),
          conflicted: true,
        );
        await storage.writeProposalRecord(
          invalid,
          expectedRecordRevision: record.recordRevision,
        );
        rethrow;
      }
      deleted = compiled.deleted;
      map = compiled.blockMap;
      note = deleted
          ? current
          : StoredNote(
              id: id,
              title: current.title,
              path: current.path,
              version: current.version + 1,
              createdAt: current.createdAt,
              updatedAt: _clock.nowUtc(),
              content: compiled.content,
              extra: current.extra,
            );
      provenance = await storage.readAcceptedProvenance(id);
      final ids = map.blocks.map((b) => b.id).toSet();
      provenance.removeWhere((id, _) => !ids.contains(id));
      for (var index = 0; index < operations.length; index++) {
        final operation = operations[index];
        if (operation.type == 'delete' || operation.type == 'delete_note') {
          continue;
        }
        final targets = operation.type == 'insert_after'
            ? compiled.introducedIdentities.entries
                .where((e) => e.key.startsWith('$index:'))
                .map((e) => e.value)
            : [operation.blockId!];
        for (final blockId in targets) {
          final block = map.blocks.where((b) => b.id == blockId).firstOrNull;
          if (block == null) continue;
          final attached = [...refs, ...operation.evidenceRefs];
          final previous = operation.type == 'attach_evidence'
              ? provenance[blockId] as Map<String, dynamic>?
              : null;
          provenance[blockId] = _association(
            block.revision,
            attached,
            operation.supersedes,
            previous: previous,
          );
        }
      }
    }
    var accepted = record.acceptedForJournal(
      expectedRecordRevision: revision,
      reviewer: _author(actor),
      at: _clock.nowUtc(),
      noteVersion: map.version,
      automatic: automatic,
    );
    if (input['comment'] != null) {
      accepted = accepted.comment(
        expectedRecordRevision: accepted.recordRevision,
        author: _author(actor),
        body: _string(input, 'comment'),
        at: _clock.nowUtc(),
        commentId: _idGenerator(),
      );
    }
    final permit = ProposalAcceptancePermit._(
      storage: storage,
      record: accepted,
      note: note,
      blockMap: map,
      provenance: provenance,
      deleted: deleted,
      newNote: newNote,
      actor: actor ?? _author(actor).label,
      policyDelta: policyDelta,
    );
    try {
      await storage.acceptProposal(
        permit,
        expectedRecordRevision: record.recordRevision,
      );
      await onAccepted(note, permit.actor, deleted: deleted);
      await storage.acknowledgeIndexedRevision(id, map.version);
    } finally {
      permit._active = false;
    }
    return accepted;
  }

  Map<String, dynamic> _association(
    int revision,
    List<EvidenceReference> refs,
    List<EvidenceReference> supersedes, {
    Map<String, dynamic>? previous,
  }) =>
      {
        'block_revision': revision,
        'source_unknown': refs.isEmpty && previous == null,
        'evidence_refs': [
          ...?previous?['evidence_refs'] as List?,
          for (final ref in refs) ref.toJson(),
        ],
        'supersedes': [
          ...?previous?['supersedes'] as List?,
          for (final ref in supersedes) ref.toJson(),
        ],
      };

  Future<List<Map<String, dynamic>>> _resolve(
    List<EvidenceReference> refs,
  ) async {
    final resolved = <Map<String, dynamic>>[];
    for (final ref in refs) {
      if (!ref.requiresResolution) {
        resolved.add({...ref.toJson(), 'resolved': false});
        continue;
      }
      if (ref.kind == 'archive') {
        authorization.requireEvidenceRead(
          currentKnowledgePrincipal,
          ref.digest!,
        );
        final evidence = await archiveReader?.call(ref.digest!);
        if (evidence == null) {
          throw const ProposalEvidenceException('archive_unavailable');
        }
        resolved.add({
          ...ref.toJson(),
          'resolved': true,
          'payload_hash': _hash(evidence['payload']),
        });
        continue;
      }
      final id = ref.noteId!;
      final source = await storage.readRevision(id, ref.noteVersion!);
      String currentPath;
      try {
        currentPath = (await storage.read(id)).path;
      } on NoteNotFoundException {
        final history = await storage.revisions(id);
        if (history.isEmpty) {
          throw const ProposalEvidenceException('source_missing');
        }
        currentPath = (parseFrontmatter(history.last['markdown'] as String)
                .metadata['path'] as String?) ??
            '';
      }
      authorization.requireHistoricalRead(
        currentKnowledgePrincipal,
        id,
        source.path,
        currentPath,
      );
      var text = source.content;
      if (ref.kind == 'block_revision') {
        final map = await storage.readBlockMap(id, version: ref.noteVersion);
        final block = map.blocks
            .where(
              (b) => b.id == ref.blockId && b.revision == ref.blockRevision,
            )
            .firstOrNull;
        if (block == null) {
          throw const ProposalEvidenceException('source_block_unavailable');
        }
        text = block.source(source.content);
      }
      resolved.add(
        {...ref.toJson(), 'resolved': true, 'content_hash': _hash(text)},
      );
    }
    return resolved;
  }
}

void _fields(Map<String, dynamic> input, Set<String> allowed) {
  if (!input.keys.every(allowed.contains)) {
    throw const FormatException('Unknown proposal request fields');
  }
}

String _string(Map<String, dynamic> input, String field, {bool empty = false}) {
  final value = input[field];
  if (value is! String || (!empty && value.trim().isEmpty)) {
    throw FormatException('$field must be a string');
  }
  return value;
}

int _revision(Map<String, dynamic> input, String field) {
  final value = input[field];
  if (value is! int || value < 1) throw FormatException('Invalid $field');
  return value;
}

String _key(Map<String, dynamic> input) => _string(input, 'idempotency_key');
List<EvidenceReference> _refs(Object? raw) {
  if (raw == null) return [];
  if (raw is! List) {
    throw const FormatException('evidence_refs must be an array');
  }
  return [
    for (final ref in raw) _reference(ref),
  ];
}

Map<String, Object?> _properties(Object? raw) {
  if (raw == null) return {};
  if (raw is! Map<String, dynamic>) {
    throw const FormatException('properties must be an object');
  }
  if (raw.keys.any(
    const {
      'id',
      'path',
      'title',
      'version',
      'created_at',
      'updated_at',
      'type',
      'source',
      'properties',
      'views',
    }.contains,
  )) {
    throw const FormatException(
      'Draft properties cannot override structural keys',
    );
  }
  return raw.cast<String, Object?>();
}

String _anchorStatus(Map<String, dynamic> comment, List<MarkdownBlock> blocks) {
  final id = comment['block_id'];
  if (id == null) return 'current';
  final matches = blocks.where((block) => block.id == id);
  if (matches.isEmpty) return 'orphaned';
  return matches.any((b) => b.revision == comment['block_revision'])
      ? 'current'
      : 'stale';
}

EvidenceReference _reference(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw const FormatException('Evidence reference must be an object');
  }
  return EvidenceReference.fromJson(raw);
}

void _commentInput(Map<String, dynamic> input) {
  for (final key in const {'block_id', 'reply_to'}) {
    if (input.containsKey(key) &&
        (input[key] is! String || (input[key] as String).trim().isEmpty)) {
      throw FormatException('Invalid $key');
    }
  }
  if (input.containsKey('block_revision') &&
      (input['block_revision'] is! int ||
          (input['block_revision'] as int) < 1)) {
    throw const FormatException('Invalid block_revision');
  }
}
