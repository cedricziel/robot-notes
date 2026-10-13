import 'dart:convert';
import 'dart:io';

import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/extraction_jobs.dart';
import 'package:server/src/knowledge/extraction_model.dart';
import 'package:server/src/knowledge/extraction_worker.dart';
import 'package:server/src/knowledge/query_service.dart';
import 'package:server/src/knowledge/source_store.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge/typed_proposals.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import 'type_definition_test.dart' show definition;

class FixtureExtractor implements KnowledgeExtractor {
  Future<void> Function()? beforeReturn;
  List<Map<String, Object?>> Function(KnowledgeExtractionInput)? findings;
  int calls = 0;
  @override
  String get fingerprint => 'fixture-v1';
  @override
  Future<List<Map<String, Object?>>> extract(
    KnowledgeExtractionInput input,
  ) async {
    calls++;
    await beforeReturn?.call();
    return findings?.call(input) ??
        [
          {
            'dispositions': ['new'],
            'reason': 'Durable fixture claim',
            'title': 'Scoped credentials',
            'statement': input.text,
            'source_quote': input.text,
            'locator': {
              'kind': 'text_range',
              'start': input.start,
              'end': input.end,
            },
          }
        ];
  }

  @override
  void close() {}
}

void main() {
  late Directory directory;
  late Storage storage;
  late KnowledgeSourceStore sources;
  late KnowledgeExtractionJobs jobs;
  late KnowledgeExtractionWorker worker;
  late FixtureExtractor extractor;
  late TypedKnowledgeProposals proposals;
  late bool originActive;
  setUp(() async {
    originActive = true;
    directory = await Directory.systemTemp.createTemp('extraction-worker-');
    final authorization =
        NoteAuthorizationService(store: KnowledgePolicyStore.memory());
    storage = Storage(contentDir: Directory('${directory.path}/notes'));
    final types = KnowledgeTypeSnapshots(
      directory: Directory('${directory.path}/types'),
      authorization: authorization,
    );
    sources = KnowledgeSourceStore(
      directory: Directory('${directory.path}/sources'),
      authorization: authorization,
    );
    jobs = KnowledgeExtractionJobs(file: File('${directory.path}/jobs.db'));
    proposals = TypedKnowledgeProposals(
      storage: storage,
      types: types,
      sources: sources,
      authorization: authorization,
      onAccepted: (_) async {},
    );
    extractor = FixtureExtractor();
    final claim = definition(
      'urn:robot-notes:type:Claim',
      properties: {
        'statement': {'value_type': 'text', 'required': true},
      },
    );
    (claim['definition']! as Map<String, Object?>)['relations'] = {
      'supported_by': {
        'target_types': [
          {'id': 'urn:robot-notes:type:Evidence', 'version': 1},
        ],
        'min_items': 1,
      },
    };
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      await types.accept(
        {
          'claim.md': serializeFrontmatter(
            Frontmatter(metadata: {'knowledge': claim}, body: ''),
          ),
          'evidence.md': serializeFrontmatter(
            Frontmatter(
              metadata: {
                'knowledge': definition('urn:robot-notes:type:Evidence'),
              },
              body: '',
            ),
          ),
        },
        expectedGeneration: 0,
      );
      await sources.configureScope(
        'scope',
        captureAdapters: {'hermes'},
        principals: {'*'},
        extractionEnabled: true,
        trigger: 'both',
      );
    });
    worker = KnowledgeExtractionWorker(
      jobs: jobs,
      sources: sources,
      types: types,
      proposals: proposals,
      queries: KnowledgeQueryService(
        storage: storage,
        types: types,
        authorization: authorization,
      ),
      extractor: extractor,
      config: KnowledgeExtractionConfig(
        endpoint: Uri.parse('https://fixture.invalid/v1'),
        model: 'fixture',
        apiKey: 'test-key',
      ),
      resolveOrigin: (id) async => id == 'operator' && originActive
          ? const KnowledgePrincipal.operator()
          : null,
    );
  });
  tearDown(() async {
    await worker.close();
    jobs.close();
    sources.close();
    await directory.delete(recursive: true);
  });

  Future<void> observe(
    String event,
    String kind, {
    String conversation = 'conversation-1',
    String text = 'Agent credentials require scoped permissions.',
  }) =>
      withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
        await sources.ingest(
          adapter: 'hermes',
          eventId: event,
          scopeId: 'scope',
          bytes: utf8.encode(text),
          mediaType: 'text/plain',
          automatic: true,
          observationKind: kind,
          conversationId: conversation,
        );
      });

  test(
      'worker submits atomic Evidence and Claim without '
      'publishing accepted text', () async {
    await observe('turn-1', 'completed_turn');
    expect(await worker.runOnce(), isTrue);
    expect(jobs.summaries().single['state'], 'completed');
    expect(await storage.list(), isEmpty);
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final records = await storage.proposalRecords();
      expect(records, hasLength(1));
      final record = records.single;
      expect(record.state, 'pending');
      expect(record.author.kind, 'agent');
      expect(
        record.current.candidate['metadata'],
        containsPair('dispositions', ['new']),
      );
      final accepted = await proposals.accept(
        record.noteId,
        record.id,
        expectedRecordRevision: 1,
      );
      expect(accepted.state, 'accepted');
      expect(await storage.list(), hasLength(2));
    });
  });

  test('generated assistant output cannot support automatic extracted claims',
      () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      await sources.ingest(
        adapter: 'hermes',
        eventId: 'assistant-only',
        scopeId: 'scope',
        bytes: utf8.encode(
          jsonEncode({
            'messages': [
              {
                'role': 'assistant',
                'content': 'Unsupported durable assertion.',
              },
            ],
          }),
        ),
        mediaType: 'application/json',
        automatic: true,
        observationKind: 'completed_turn',
        conversationId: 'conversation-1',
      );
    });
    await worker.runOnce();
    expect(jobs.summaries().single['state'], 'blocked');
    expect(jobs.summaries().single['diagnostic'], 'generated_answer_only');
    expect(await storage.proposalRecords(), isEmpty);
    expect(await storage.list(), isEmpty);
  });

  test('unchanged pending claims are suppressed across conversations',
      () async {
    await observe('first', 'session_end');
    await worker.runOnce();
    await observe('second', 'session_end', conversation: 'conversation-2');
    await worker.runOnce();
    expect(await storage.proposalRecords(), hasLength(1));
    expect(
      jobs.summaries().map((job) => job['state']),
      everyElement('completed'),
    );
  });

  test('both triggers suppress unchanged candidates across source revisions',
      () async {
    await observe('turn-1', 'completed_turn');
    await worker.runOnce();
    await observe('session-end', 'session_end');
    await worker.runOnce();
    expect(jobs.summaries(), hasLength(2));
    expect(await storage.proposalRecords(), hasLength(1));
  });

  test(
      'disabling extraction during model processing prevents '
      'proposal submission', () async {
    extractor.beforeReturn = () => withKnowledgePrincipal(
          const KnowledgePrincipal.operator(),
          () => sources.configureScope(
            'scope',
            captureAdapters: {'hermes'},
            principals: {'*'},
          ),
        );
    await observe('turn-1', 'completed_turn');
    await worker.runOnce();
    expect(jobs.summaries().single['state'], 'cancelled');
    expect(await storage.proposalRecords(), isEmpty);
  });

  test('explicit replay uses a separate idempotent generation', () async {
    await observe('original', 'session_end');
    await worker.runOnce();
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final source = (await sources.list()).single;
      final replay = await worker.reextract(
        source.id,
        source.revision,
        generation: 'manual-1',
      );
      expect(
        await worker.reextract(
          source.id,
          source.revision,
          generation: 'manual-1',
        ),
        replay,
      );
      expect(jobs.summaries(), hasLength(2));
    });
    await worker.runOnce();
    expect(await storage.proposalRecords(), hasLength(1));
    expect(
      jobs.summaries().map((job) => job['state']),
      everyElement('completed'),
    );
  });

  test('type upgrades affect future observations without repinning queued jobs',
      () async {
    await observe('before-upgrade', 'session_end');
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final upgraded = definition(
        'urn:robot-notes:type:Claim',
        properties: {
          'statement': {'value_type': 'text', 'required': true},
        },
      );
      (upgraded['definition']! as Map<String, Object?>)['version'] = 2;
      await proposals.types.accept(
        {
          'claim-v2.md': serializeFrontmatter(
            Frontmatter(
              metadata: {'knowledge': upgraded},
              body: 'Revised authoring guidance',
            ),
          ),
        },
        expectedGeneration: 1,
      );
    });
    await observe('after-upgrade', 'session_end');
    final first = jobs.claim()!;
    final second = jobs.claim()!;
    List<Map<String, dynamic>> pins(Map<String, dynamic> job) =>
        ((job['config'] as Map)['types'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
    expect(
      pins(first)
          .where((pin) => pin['id'] == 'urn:robot-notes:type:Claim')
          .single['version'],
      1,
    );
    expect(
      pins(second)
          .where((pin) => pin['id'] == 'urn:robot-notes:type:Claim')
          .single['version'],
      2,
    );
  });

  test('source purge during extraction prevents candidate submission',
      () async {
    extractor.beforeReturn = () => withKnowledgePrincipal(
          const KnowledgePrincipal.operator(),
          () async {
            final source = (await sources.list()).single;
            await sources.purge(source.id, source.revision);
          },
        );
    await observe('purged-source', 'session_end');
    await worker.runOnce();
    expect(jobs.summaries().single['state'], 'cancelled');
    expect(await storage.proposalRecords(), isEmpty);
  });

  test('revoked originating credentials prevent candidate submission',
      () async {
    extractor.beforeReturn = () async {
      originActive = false;
    };
    await observe('revoked-origin', 'session_end');
    await worker.runOnce();
    expect(jobs.summaries().single['state'], 'cancelled');
    expect(await storage.proposalRecords(), isEmpty);
  });

  test('distinct entities sharing properties are not collapsed as duplicates',
      () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      await proposals.types.accept(
        {
          'project.md': serializeFrontmatter(
            Frontmatter(
              metadata: {
                'knowledge': definition(
                  'urn:robot-notes:type:Project',
                  properties: {
                    'summary': {'value_type': 'text', 'required': true},
                  },
                ),
              },
              body: 'Projects',
            ),
          ),
        },
        expectedGeneration: 1,
      );
    });
    extractor.findings = (input) => [
          for (final title in ['Project Alpha', 'Project Beta'])
            {
              'dispositions': ['new'],
              'reason': 'Distinct sourced project identity',
              'title': title,
              'type_id': 'urn:robot-notes:type:Project',
              'statement': input.text,
              'properties': {'summary': 'Shared tooling'},
              'source_quote': input.text,
              'locator': {
                'kind': 'text_range',
                'start': input.start,
                'end': input.end,
              },
            },
        ];
    await observe(
      'projects',
      'session_end',
      text: 'Project Alpha and Project Beta have the summary Shared tooling.',
    );
    await worker.runOnce();
    expect(await storage.proposalRecords(), hasLength(2));
  });
}
