import 'dart:convert';
import 'dart:io';

import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/source_store.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late KnowledgeSourceStore sources;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('knowledge-sources-');
    sources = KnowledgeSourceStore(
      directory: directory,
      authorization:
          NoteAuthorizationService(store: KnowledgePolicyStore.memory()),
    );
    await withKnowledgePrincipal(
      const KnowledgePrincipal.operator(),
      () => sources.configureScope(
        'scope-1',
        captureAdapters: {'hermes'},
        principals: {'*'},
      ),
    );
  });
  tearDown(() async {
    sources.close();
    await directory.delete(recursive: true);
  });
  test('scoped retries preserve bytes and conflict when scope changes',
      () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final bytes = utf8.encode('---\nknowledge: forged\n---\nA😀B');
      final first = await sources.ingest(
        adapter: 'hermes',
        eventId: 'turn-1',
        scopeId: 'scope-1',
        bytes: bytes,
        mediaType: 'TEXT/MARKDOWN',
        automatic: true,
      );
      final retry = await sources.ingest(
        adapter: 'hermes',
        eventId: 'turn-1',
        scopeId: 'scope-1',
        bytes: bytes,
        mediaType: 'text/markdown',
        automatic: true,
      );
      expect(retry.revision, first.revision);
      expect(await sources.inspect(first.id, first.revision), bytes);
      await sources.configureScope(
        'scope-2',
        captureAdapters: {'hermes'},
        principals: {'*'},
      );
      await expectLater(
        sources.ingest(
          adapter: 'hermes',
          eventId: 'turn-1',
          scopeId: 'scope-2',
          bytes: bytes,
          mediaType: 'text/markdown',
          automatic: true,
        ),
        throwsA(isA<SourceDeliveryConflict>()),
      );
    });
  });
  test('Unicode scalar ranges stay pinned and purge prevents retry recreation',
      () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final bytes = utf8.encode('A😀B');
      final source = await sources.ingest(
        adapter: 'upload',
        eventId: 'doc-1',
        scopeId: 'scope-1',
        bytes: bytes,
        mediaType: 'text/plain',
      );
      expect(
        await sources.passage(
          source.id,
          source.revision,
          {'kind': 'text_range', 'start': 1, 'end': 2},
        ),
        '😀',
      );
      await expectLater(
        sources.passage(
          source.id,
          source.revision,
          {'kind': 'text_range', 'start': 1, 'end': 4},
        ),
        throwsFormatException,
      );
      await sources.purge(source.id, source.revision);
      await expectLater(
        sources.inspect(source.id, source.revision),
        throwsA(isA<SourceUnavailable>()),
      );
      await expectLater(
        sources.ingest(
          adapter: 'upload',
          eventId: 'doc-1',
          scopeId: 'scope-1',
          bytes: bytes,
          mediaType: 'text/plain',
        ),
        throwsA(isA<SourceUnavailable>()),
      );
    });
  });
  test('new source revision never redirects old Evidence passages', () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      final original = await sources.ingest(
        adapter: 'upload',
        eventId: 'v1',
        scopeId: 'scope-1',
        bytes: utf8.encode('Old statement'),
        mediaType: 'text/plain',
      );
      final updated = await sources.ingest(
        adapter: 'upload',
        eventId: 'v2',
        scopeId: 'scope-1',
        bytes: utf8.encode('New statement'),
        mediaType: 'text/plain',
        sourceId: original.id,
      );
      expect(updated.id, original.id);
      expect(updated.revision, isNot(original.revision));
      final metadata = parseFrontmatter(
        await File(
          '${directory.path}/descriptors/${original.id}.md',
        ).readAsString(),
      ).metadata;
      expect(metadata['created_at'], original.capturedAt.toIso8601String());
      expect(metadata['updated_at'], updated.capturedAt.toIso8601String());
      expect(metadata['version'], 2);
      expect(
        await sources.passage(
          original.id,
          original.revision,
          {'kind': 'whole_document'},
        ),
        'Old statement',
      );
      await File('${directory.path}/descriptors/${original.id}.md').delete();
      expect(
        await sources.inspect(updated.id, updated.revision),
        utf8.encode('New statement'),
      );
      expect(
        File('${directory.path}/descriptors/${original.id}.md').existsSync(),
        isTrue,
      );
    });
  });

  test('capture-disabled adapter cannot create a source', () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      await expectLater(
        sources.ingest(
          adapter: 'disabled',
          eventId: 'turn-1',
          scopeId: 'scope-1',
          bytes: utf8.encode('Claim'),
          mediaType: 'text/plain',
          automatic: true,
        ),
        throwsA(isA<KnowledgeAccessDeniedException>()),
      );
      expect(await sources.list(), isEmpty);
    });
  });

  test('a delivery retry cannot change its boundary or conversation', () async {
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      Future<KnowledgeSourceRevision> deliver(
        String kind,
        String conversation,
      ) =>
          sources.ingest(
            adapter: 'hermes',
            eventId: 'same-event',
            scopeId: 'scope-1',
            bytes: utf8.encode('Original source.'),
            mediaType: 'text/plain',
            automatic: true,
            observationKind: kind,
            conversationId: conversation,
          );
      await deliver('completed_turn', 'conversation-1');
      await expectLater(
        deliver('session_end', 'conversation-1'),
        throwsA(isA<SourceDeliveryConflict>()),
      );
      await expectLater(
        deliver('completed_turn', 'conversation-2'),
        throwsA(isA<SourceDeliveryConflict>()),
      );
    });
  });
}
