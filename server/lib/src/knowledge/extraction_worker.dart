import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:server/src/knowledge/canonical_json.dart';
import 'package:server/src/knowledge/extraction_jobs.dart';
import 'package:server/src/knowledge/extraction_model.dart';
import 'package:server/src/knowledge/query_service.dart';
import 'package:server/src/knowledge/source_store.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge/typed_proposals.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/proposals/proposal_record.dart';

/// Proposal-only server worker using the shared source, query, and review
/// services.
class KnowledgeExtractionWorker {
  /// Requires a current credential resolver; stale source principals cannot run
  /// work.
  KnowledgeExtractionWorker({
    required this.jobs,
    required this.sources,
    required this.types,
    required this.proposals,
    required this.queries,
    required this.extractor,
    required this.config,
    required this.resolveOrigin,
  }) {
    sources.onObservation = observe;
    sources.onScopeChanged = (id) async {
      if (sources.scopeSettings(id)['extraction_enabled'] != true) {
        jobs.cancelScope(id);
      }
    };
    sources.onPurge = (id, revision) async => jobs.purgeSource(id, revision);
  }

  /// Durable scheduler leases and checkpoints.
  final KnowledgeExtractionJobs jobs;

  /// Scope-aware immutable original sources.
  final KnowledgeSourceStore sources;

  /// Accepted pinned constraints and guidance.
  final KnowledgeTypeSnapshots types;

  /// Shared proposal submission; never invokes acceptance.
  final TypedKnowledgeProposals proposals;

  /// Accepted-only knowledge under the originating principal's read access.
  final KnowledgeQueryService queries;

  /// Bounded model implementation or deterministic contract fixture.
  final KnowledgeExtractor extractor;

  /// Frozen non-secret job settings and separate model credentials.
  final KnowledgeExtractionConfig config;

  /// Rechecks current provisioning, expiration, and revocation by stable
  /// identity.
  final Future<KnowledgePrincipal?> Function(String id) resolveOrigin;
  final _log = Logger('knowledge_extraction');
  Timer? _timer;
  Future<bool>? _running;
  bool _closing = false;

  KnowledgePrincipal get _worker => KnowledgePrincipal.agent(
        credentialId: 'server-extraction:${sources.authorization.vaultId}',
        scopes: {'notes:read', 'knowledge:propose'},
        vaultIds: {sources.authorization.vaultId},
      );
  String _hash(Object value) =>
      sha256.convert(utf8.encode(canonicalKnowledgeJson(value))).toString();

  /// Enqueues only originally eligible observations; config changes do not
  /// replay history.
  Future<void> observe(KnowledgeSourceRevision source) async {
    if (!source.extractionEligible) return;
    final settings = sources.scopeSettings(source.scopeId);
    if (settings['extraction_enabled'] != true ||
        settings['revision'] != source.scopeRevision) {
      return;
    }
    await _enqueue(source, 'initial');
  }

  /// Starts explicit replay under human policy authority with a new generation.
  Future<String> reextract(
    String sourceId,
    String revision, {
    required String generation,
  }) async {
    sources.authorization.require(
      currentKnowledgePrincipal,
      KnowledgeAction.policy,
      KnowledgeTarget.folder('sources'),
    );
    if (generation == 'initial' ||
        !RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(generation)) {
      throw const FormatException('Invalid explicit extraction generation');
    }
    final source = sources.descriptor(sourceId, revision);
    await _eligible(source);
    return _enqueue(source, generation);
  }

  Future<String> _enqueue(
    KnowledgeSourceRevision source,
    String generation,
  ) async {
    final definitions = await types.definitions();
    final local = <String, KnowledgeTypeDefinition>{
      for (final definition in definitions)
        if (definition.id.startsWith('urn:robot-notes:type:'))
          definition.id: definition,
    };
    final references = local.values
        .map((definition) => definition.reference.toJson())
        .toList();
    return jobs.enqueue(
      id: _hash([source.id, source.revision, generation]),
      sourceId: source.id,
      revision: source.revision,
      scopeId: source.scopeId,
      originId: source.principalId,
      generation: generation,
      coalesceKey: generation == 'initial' &&
              source.observationKind == 'completed_turn' &&
              source.conversationId != null
          ? _hash([
              source.scopeId,
              source.principalId,
              source.adapter,
              source.conversationId!,
              extractor.fingerprint,
              references,
              source.scopeRevision,
            ])
          : null,
      config: {
        'extractor': extractor.fingerprint,
        'types': references,
        'source': source.toJson(),
      },
    );
  }

  /// Starts one bounded poll loop; overlapping ticks never claim another local
  /// job.
  void start({Duration interval = const Duration(seconds: 2)}) {
    _timer ??= Timer.periodic(interval, (_) {
      unawaited(runOnce());
    });
  }

  /// Processes at most one leased job; fixtures call this without starting a
  /// timer.
  Future<bool> runOnce() {
    if (_closing) return Future.value(false);
    return _running ??= withKnowledgePrincipal(_worker, _process)
        .whenComplete(() => _running = null);
  }

  Future<KnowledgePrincipal> _eligible(KnowledgeSourceRevision source) async {
    if (_closing) throw const KnowledgeExtractionFailure('worker_stopped');
    final settings = sources.scopeSettings(source.scopeId);
    if (settings['extraction_enabled'] != true) {
      throw const KnowledgeExtractionFailure('scope_disabled');
    }
    sources.descriptor(source.id, source.revision);
    final origin = await resolveOrigin(source.principalId);
    if (origin == null) {
      throw const KnowledgeAccessDeniedException(KnowledgeAction.read);
    }
    await withKnowledgePrincipal(origin, () async {
      sources.scopeSettings(source.scopeId);
      sources.authorization.require(
        origin,
        KnowledgeAction.propose,
        KnowledgeTarget.folder('knowledge'),
      );
    });
    return origin;
  }

  Future<List<Map<String, Object?>>> _pending(KnowledgePrincipal origin) =>
      withKnowledgePrincipal(origin, () async {
        final result = <Map<String, Object?>>[];
        for (final record in await proposals.storage.proposalRecords()) {
          if (record.current.candidate['kind'] != 'typed_knowledge' ||
              const {'accepted', 'denied'}.contains(record.state)) {
            continue;
          }
          try {
            final inspected = await proposals.inspect(record.noteId, record.id);
            await withKnowledgePrincipal(
              _worker,
              () => proposals.inspect(record.noteId, record.id),
            );
            result.add({
              'proposal_id': record.id,
              'state': record.state,
              'candidate': inspected.current.candidate,
            });
          } on KnowledgeAccessDeniedException {
            continue;
          }
          if (result.length == 50) break;
        }
        return result;
      });

  Future<List<Map<String, Object?>>> _accepted(KnowledgePrincipal origin) =>
      withKnowledgePrincipal(
        origin,
        () async {
          final entries =
              ((await queries.query({'limit': 200}))['items']! as List<Object?>)
                  .cast<Map<String, Object?>>();
          final result = <Map<String, Object?>>[];
          for (final entry in entries) {
            final note = await proposals.storage.read(entry['id']! as String);
            try {
              proposals.authorization.requireHistoricalRead(
                _worker,
                note.id,
                entry['path']! as String,
                note.path,
              );
              result.add(entry);
            } on KnowledgeAccessDeniedException {
              continue;
            }
          }
          return result;
        },
      );

  bool _groundedValues(Object? value, String passage) {
    if (value is Map<String, Object?>) {
      return value.values.every((item) => _groundedValues(item, passage));
    }
    if (value is List<Object?>) {
      return value.every((item) => _groundedValues(item, passage));
    }
    final text = value?.toString() ?? '';
    final literals =
        RegExp(r'\b\d{4}-\d{2}-\d{2}\b|\b\d+(?:[.,]\d+)*(?:[kKmMbB%])?\b');
    return literals
        .allMatches(text)
        .every((match) => passage.contains(match.group(0)!));
  }

  Future<bool> _independentSupport(
    KnowledgeSourceRevision source,
    String passage,
  ) async {
    if (source.observationKind == 'import' ||
        !source.mediaType.startsWith('application/json')) {
      return true;
    }
    final raw = jsonDecode(
      utf8.decode(await sources.inspect(source.id, source.revision)),
    );
    if (raw is! Map<String, dynamic> || raw['messages'] is! List<dynamic>) {
      return false;
    }
    for (final message in raw['messages'] as List<dynamic>) {
      if (message is! Map<String, dynamic> ||
          !const {'user', 'tool'}.contains(message['role'])) {
        continue;
      }
      final content = message['content'];
      if (content is String &&
          (content.contains(passage) ||
              jsonEncode(content).contains(passage))) {
        return true;
      }
      if (content is List<dynamic> && jsonEncode(content).contains(passage)) {
        return true;
      }
    }
    return false;
  }

  Future<Map<String, Object?>> _prepare(
    KnowledgeSourceRevision source,
    Map<String, Object?> finding,
    List<Map<String, Object?>> accepted,
    List<Map<String, Object?>> ongoing,
    List<KnowledgeTypeReference> pinned,
    int start,
    int end,
  ) async {
    final dispositions =
        (finding['dispositions']! as List<Object?>).cast<String>();
    if (dispositions.isEmpty ||
        dispositions.any(
          (value) => !const {
            'new',
            'update',
            'disputed',
            'no_material',
          }.contains(value),
        ) ||
        (dispositions.contains('no_material') && dispositions.length != 1)) {
      throw const KnowledgeExtractionFailure('classification_invalid');
    }
    if (finding['reason'] is! String ||
        (finding['reason']! as String).trim().isEmpty) {
      throw const KnowledgeExtractionFailure('classification_reason_missing');
    }
    if (dispositions.singleOrNull == 'no_material') {
      return {'dispositions': dispositions, 'reason': finding['reason']};
    }
    final locator =
        Map<String, Object?>.from(finding['locator']! as Map<String, Object?>);
    if (locator['kind'] != 'text_range' ||
        locator['start'] is! int ||
        locator['end'] is! int ||
        (locator['start']! as int) < start ||
        (locator['end']! as int) > end) {
      throw const KnowledgeExtractionFailure('locator_unverified');
    }
    final passage = await sources.passage(source.id, source.revision, locator);
    if (finding['source_quote'] != passage || passage.isEmpty) {
      throw const KnowledgeExtractionFailure('quote_unverified');
    }
    if (!await _independentSupport(source, passage)) {
      throw const KnowledgeExtractionFailure('generated_answer_only');
    }
    final statement = finding['statement'] as String? ?? '';
    final properties = Map<String, Object?>.from(
      finding['properties'] as Map<String, Object?>? ?? {},
    );
    if (!_groundedValues(statement, passage) ||
        !_groundedValues(properties, passage)) {
      throw const KnowledgeExtractionFailure('literal_unverified');
    }
    final typeId =
        finding['type_id'] as String? ?? 'urn:robot-notes:type:Claim';
    final matching = pinned.where((type) => type.id == typeId).toList();
    if (matching.length != 1) {
      throw const KnowledgeExtractionFailure('type_ambiguous');
    }
    if (typeId == 'urn:robot-notes:type:Claim') {
      if (statement.trim().isEmpty) {
        throw const KnowledgeExtractionFailure('statement_missing');
      }
      properties['statement'] = statement;
    }
    final targetId = finding['target_id'] as String?;
    final title = finding['title'] as String? ?? '';
    bool unchanged(Map<String, Object?> entry) {
      final assigned = entry['types'] as List<Object?>? ?? const [];
      final existing = entry['properties'] as Map<String, Object?>? ?? const {};
      return assigned.any((type) => (type! as Map)['id'] == typeId) &&
          (entry['title'] as String? ?? '').trim().toLowerCase() ==
              title.trim().toLowerCase() &&
          properties.isNotEmpty &&
          properties.entries.every(
            (entry) =>
                canonicalKnowledgeJson(existing[entry.key]) ==
                canonicalKnowledgeJson(entry.value),
          );
    }

    if (!dispositions.contains('disputed') &&
        (accepted.any(unchanged) ||
            ongoing.any((proposal) {
              final candidate = proposal['candidate']! as Map<String, Object?>;
              return (candidate['operations']! as List<Object?>).any(
                (operation) => unchanged(operation! as Map<String, Object?>),
              );
            }))) {
      return {
        'dispositions': ['no_material'],
        'reason': 'Unchanged finding already accepted or awaiting review.',
      };
    }
    final targets = accepted.where((entry) => entry['id'] == targetId).toList();
    if ((dispositions.contains('update') ||
            dispositions.contains('disputed')) &&
        targets.length != 1) {
      throw const KnowledgeExtractionFailure('target_ambiguous');
    }
    if (targetId != null && targets.length != 1) {
      throw const KnowledgeExtractionFailure('target_unavailable');
    }
    if (title.trim().isEmpty || title.length > 256 || statement.length > 4096) {
      throw const KnowledgeExtractionFailure('candidate_limit');
    }
    final fingerprint = _hash([
      typeId,
      targetId,
      title.trim().toLowerCase(),
      properties,
    ]);
    final namespace = _hash([
      source.scopeId,
      source.principalId,
      source.adapter,
      source.conversationId ?? source.id,
      extractor.fingerprint,
    ]);
    final duplicate = jobs.fingerprint(namespace, fingerprint);
    if (duplicate != null) {
      return {
        'dispositions': ['no_material'],
        'reason': 'Unchanged finding already proposed.',
      };
    }
    final previous = targets.isEmpty ? null : targets.single;
    final relations = <String, Object?>{
      ...?previous?['relations'] as Map<String, Object?>?,
      ...?finding['relations'] as Map<String, Object?>?,
    };
    if (const {
      'urn:robot-notes:type:Claim',
      'urn:robot-notes:type:Decision',
      'urn:robot-notes:type:Procedure',
    }.contains(typeId)) {
      relations['supported_by'] = [
        ...((previous?['relations'] as Map?)?['supported_by'] as List? ??
            const <Object?>[]),
        {'local_ref': 'evidence'},
      ];
    }
    final evidenceType = pinned
        .where((type) => type.id == 'urn:robot-notes:type:Evidence')
        .toList();
    if (evidenceType.length != 1) {
      throw const KnowledgeExtractionFailure('evidence_type_unavailable');
    }
    final heading =
        dispositions.contains('disputed') ? 'Disputed finding' : title;
    final priorContent = previous == null
        ? ''
        : 'Previous accepted content:\n${previous['content']}\n\n';
    final body = '$heading\n\n$statement\n\n'
        '${priorContent}Supporting passage:\n$passage\n';
    final operations = <Object?>[
      {
        'kind': 'create',
        'local_ref': 'evidence',
        'title': 'Evidence ${fingerprint.substring(0, 12)}',
        'types': [evidenceType.single.toJson()],
        'content': passage,
        'evidence': {
          'source_id': source.id,
          'source_revision': source.revision,
          'locator': locator,
        },
      },
      {
        'kind': previous == null ? 'create' : 'update',
        if (previous == null) 'local_ref': 'finding' else 'id': previous['id'],
        if (previous != null) 'expected_revision': previous['revision'],
        'title': previous?['title'] ?? title,
        'types': [matching.single.toJson()],
        'content': body,
        'properties': properties,
        'relations': relations,
      },
    ];
    return {
      'dispositions': dispositions,
      'operations': operations,
      'namespace': namespace,
      'fingerprint': fingerprint,
      'reason': finding['reason'],
      'context_paths': {
        for (final entry in accepted) entry['id']! as String: [entry['path']],
        for (final proposal in ongoing)
          ...?((proposal['candidate']! as Map<String, Object?>)['read_paths']
              as Map<String, Object?>?),
      },
      'context_scopes': {
        for (final proposal in ongoing)
          ...?((proposal['candidate']! as Map<String, Object?>)['read_scopes']
              as List<Object?>?),
      }.toList(),
      'metadata': {
        'dispositions': dispositions,
        'reason': finding['reason'],
        'inference': finding['inference'] == true,
        'related_targets': finding['related_targets'] ?? <Object?>[],
        'source_refs': [
          {
            'source_id': source.id,
            'source_revision': source.revision,
            'locator': locator,
          },
        ],
      },
    };
  }

  Future<bool> _process() async {
    final job = jobs.claim(lease: config.timeout * 3);
    if (job == null) return false;
    final id = job['id'] as String;
    final owner = job['lease_owner'] as String;
    final frozen = job['config'] as Map<String, dynamic>;
    final checkpoint =
        Map<String, Object?>.from(job['checkpoint'] as Map<String, dynamic>);
    try {
      if (frozen['extractor'] != extractor.fingerprint) {
        throw const KnowledgeExtractionFailure('configuration_changed');
      }
      final sourceRecords =
          (frozen['sources'] as List<dynamic>?) ?? [frozen['source']];
      final pinned = (frozen['types'] as List<dynamic>)
          .map(KnowledgeTypeReference.fromJson)
          .toList();
      final resolver = KnowledgeTypeResolver(await types.definitions());
      final definitions = pinned
          .map((reference) => resolver.resolve(reference).toMetadata())
          .toList();
      while (true) {
        final sourceIndex = checkpoint['source_index'] as int? ?? 0;
        if (sourceIndex >= sourceRecords.length) {
          jobs.finish(id, owner, 'completed');
          return true;
        }
        final source = KnowledgeSourceRevision.fromJson(
          sourceRecords[sourceIndex] as Map<String, dynamic>,
        );
        final origin = await _eligible(source);
        var pending = checkpoint['pending'] as Map<String, Object?>?;
        if (pending == null) {
          final bytes = await sources.inspect(source.id, source.revision);
          if (!source.mediaType.startsWith('text/') &&
              !source.mediaType.startsWith('application/json')) {
            throw const KnowledgeExtractionFailure('unsupported_media');
          }
          final scalars = utf8.decode(bytes).runes.toList();
          final start = checkpoint['offset']! as int;
          if (start >= scalars.length) {
            checkpoint['source_index'] = sourceIndex + 1;
            checkpoint['offset'] = 0;
            if (!jobs.checkpoint(
              id,
              owner,
              checkpoint,
              lease: config.timeout * 3,
            )) {
              return true;
            }
            continue;
          }
          if ((checkpoint['chunks']! as int) >= config.maxChunks) {
            throw const KnowledgeExtractionFailure('input_limit');
          }
          final end = (start + config.maxInputScalars).clamp(0, scalars.length);
          final accepted = await _accepted(origin);
          final ongoing = await _pending(origin);
          final candidates = await extractor.extract(
            KnowledgeExtractionInput(
              text: String.fromCharCodes(scalars.sublist(start, end)),
              start: start,
              end: end,
              accepted: accepted,
              pending: ongoing,
              types: definitions,
            ),
          );
          if (candidates.length > config.maxCandidates) {
            throw const KnowledgeExtractionFailure('candidate_limit');
          }
          await _eligible(source);
          final prepared = <Map<String, Object?>>[];
          for (final candidate in candidates) {
            prepared.add(
              await _prepare(
                source,
                candidate,
                accepted,
                ongoing,
                pinned,
                start,
                end,
              ),
            );
          }
          pending = {'end': end, 'cursor': 0, 'prepared': prepared};
          checkpoint['pending'] = pending;
          if (!jobs.checkpoint(
            id,
            owner,
            checkpoint,
            lease: config.timeout * 3,
          )) {
            return true;
          }
        }
        final prepared = pending['prepared']! as List<Object?>;
        for (var index = pending['cursor']! as int;
            index < prepared.length;
            index++) {
          final candidate = prepared[index]! as Map<String, Object?>;
          if (candidate.containsKey('operations')) {
            await sources.authorization.store.withMutationLock(() async {
              final origin = await _eligible(source);
              if (jobs.fingerprint(
                    candidate['namespace']! as String,
                    candidate['fingerprint']! as String,
                  ) !=
                  null) {
                return;
              }
              final operations = candidate['operations']! as List<Object?>;
              await withKnowledgePrincipal(
                origin,
                () => proposals.validate(operations),
              );
              final proposal = await proposals.propose(
                operations,
                idempotencyKey: 'extraction:$id:$sourceIndex:'
                    '${checkpoint['offset']}:$index',
                metadata: candidate['metadata']! as Map<String, Object?>,
                contextPaths: {
                  for (final entry
                      in (candidate['context_paths']! as Map<String, Object?>)
                          .entries)
                    entry.key: (entry.value! as List<Object?>).cast<String>(),
                },
                contextScopes: (candidate['context_scopes']! as List<Object?>)
                    .cast<String>(),
              );
              final receipt = {
                'proposal_id': proposal.id,
                'note_id': proposal.noteId,
                'state': proposal.state,
              };
              jobs.recordFingerprint(
                candidate['namespace']! as String,
                candidate['fingerprint']! as String,
                receipt,
              );
              (checkpoint['submitted']! as List<Object?>).add(receipt);
            });
          }
          pending['cursor'] = index + 1;
          if (!jobs.checkpoint(
            id,
            owner,
            checkpoint,
            lease: config.timeout * 3,
          )) {
            return true;
          }
        }
        final classifications =
            (checkpoint['classifications'] as List<Object?>? ?? <Object?>[])
              ..addAll(
                prepared.map((item) {
                  final finding = item! as Map<String, Object?>;
                  return {
                    'dispositions': finding['dispositions'],
                    'reason': finding['reason'],
                  };
                }),
              );
        checkpoint['classifications'] = classifications;
        checkpoint['offset'] = pending['end'];
        checkpoint['chunks'] = (checkpoint['chunks']! as int) + 1;
        checkpoint['pending'] = null;
        if (!jobs.checkpoint(
          id,
          owner,
          checkpoint,
          lease: config.timeout * 3,
        )) {
          return true;
        }
      }
    } on KnowledgeAccessDeniedException {
      jobs.finish(id, owner, 'cancelled', diagnostic: 'authorization_revoked');
    } on SourceUnavailable {
      jobs.finish(id, owner, 'blocked', diagnostic: 'source_unavailable');
    } on KnowledgeExtractionFailure catch (error) {
      final attempts = job['attempts'] as int;
      final retry = error.transient && attempts < config.maxAttempts;
      jobs.finish(
        id,
        owner,
        const {'scope_disabled', 'worker_stopped'}.contains(error.code)
            ? 'cancelled'
            : retry
                ? 'retry_wait'
                : 'blocked',
        diagnostic: error.code,
        retryAfter: Duration(seconds: 1 << attempts.clamp(0, 8)),
      );
    } on ProposalRecordConflictException {
      jobs.finish(id, owner, 'blocked', diagnostic: 'proposal_conflict');
    } on FormatException {
      jobs.finish(id, owner, 'blocked', diagnostic: 'validation_failed');
    } on Object {
      jobs.finish(id, owner, 'blocked', diagnostic: 'worker_failure');
      _log.warning('Extraction job failed before completion');
    }
    return true;
  }

  /// Stops polling and drains the active attempt before closing model
  /// resources.
  Future<void> close() async {
    _closing = true;
    _timer?.cancel();
    _timer = null;
    extractor.close();
    await _running;
    sources.onObservation = null;
    sources.onScopeChanged = null;
    sources.onPurge = null;
  }
}
