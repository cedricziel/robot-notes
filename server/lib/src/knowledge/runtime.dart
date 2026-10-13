import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/knowledge/extraction_jobs.dart';
import 'package:server/src/knowledge/extraction_model.dart';
import 'package:server/src/knowledge/extraction_worker.dart';
import 'package:server/src/knowledge/query_service.dart';
import 'package:server/src/knowledge/source_store.dart';
import 'package:server/src/knowledge/type_review.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge/typed_proposals.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';

/// Lazy selected-vault services; disabled deployments create no new stores.
class KnowledgeRuntime {
  /// Reuses existing authority, note publication, and accepted indexing.
  KnowledgeRuntime({
    required this.enabled,
    required this.storage,
    required this.authorization,
    required this.writes,
    required this.resolveOrigin,
    this.extractionConfig,
    this.clock = const Clock(),
    KnowledgeExtractor? extractor,
  }) : _extractor = extractor;

  /// Explicit server feature activation, independent of per-scope capture.
  final bool enabled;

  /// Canonical accepted note store for the selected vault.
  final Storage storage;

  /// Selected-vault policy and trusted capabilities.
  final NoteAuthorizationService authorization;

  /// Existing index and broadcast publication callbacks.
  final NoteWriteService writes;

  /// Current credential authority, including root-owned grants for child
  /// vaults.
  final Future<KnowledgePrincipal?> Function(String id) resolveOrigin;

  /// Separate extraction model configuration; never exposed through
  /// capabilities.
  final KnowledgeExtractionConfig? extractionConfig;

  /// Injectable lifecycle timestamps.
  final Clock clock;
  KnowledgeExtractor? _extractor;
  KnowledgeSourceStore? _sources;
  KnowledgeExtractionJobs? _jobs;
  KnowledgeExtractionWorker? _worker;
  Directory get _root =>
      Directory('${storage.contentDir.parent.path}/knowledge-store');

  /// Accepted filesystem type snapshots and ontology artifacts.
  late final types = KnowledgeTypeSnapshots(
    directory: _root,
    authorization: authorization,
    clock: clock,
  );

  /// Dedicated immutable definition candidate review.
  late final typeReview = KnowledgeTypeReview(snapshots: types, clock: clock);

  /// Original source blobs, capture scopes, and consumed-key tombstones.
  KnowledgeSourceStore get sources => _sources ??= KnowledgeSourceStore(
        directory: Directory('${_root.path}/sources'),
        authorization: authorization,
        clock: clock,
      );

  /// Complete typed candidates and atomic ordinary-note acceptance.
  late final proposals = TypedKnowledgeProposals(
    storage: storage,
    types: types,
    sources: sources,
    authorization: authorization,
    onAccepted: (note) => writes.indexAcceptedProposal(
      note,
      currentKnowledgePrincipal.id,
      deleted: false,
    ),
    clock: clock,
  );

  /// Accepted-only query and traversal contract.
  late final queries = KnowledgeQueryService(
    storage: storage,
    types: types,
    authorization: authorization,
  );

  /// Durable extraction scheduler; no model request occurs during construction.
  KnowledgeExtractionJobs get jobs => _jobs ??= KnowledgeExtractionJobs(
        file: File('${_root.path}/extraction.db'),
        clock: clock,
      );

  /// Creates a proposal-only worker only when its destination is fully
  /// configured.
  KnowledgeExtractionWorker? get worker {
    if (!enabled || extractionConfig == null) return null;
    return _worker ??= KnowledgeExtractionWorker(
      jobs: jobs,
      sources: sources,
      types: types,
      proposals: proposals,
      queries: queries,
      extractor: _extractor ??=
          OpenAiCompatibleKnowledgeExtractor(extractionConfig!),
      config: extractionConfig!,
      resolveOrigin: resolveOrigin,
    );
  }

  /// Resumes durable work after credential authority and vault startup are
  /// ready.
  void start() {
    worker?.start();
  }

  /// Stops model activity before closing vault-local databases.
  Future<void> close() async {
    await _worker?.close();
    _jobs?.close();
    _sources?.close();
  }
}
