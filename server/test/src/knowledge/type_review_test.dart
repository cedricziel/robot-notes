import 'dart:io';

import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/type_review.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:test/test.dart';

import 'type_definition_test.dart' show definition;

void main() {
  late Directory directory;
  late KnowledgeTypeReview review;
  late KnowledgeTypeSnapshots snapshots;
  final agent = KnowledgePrincipal.agent(
    credentialId: 'writer',
    scopes: {'notes:read', 'knowledge:propose'},
  );
  String document(String body) => serializeFrontmatter(
        Frontmatter(
          metadata: {'knowledge': definition('urn:test:Claim')},
          body: body,
        ),
      );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('type-review-');
    snapshots = KnowledgeTypeSnapshots(
      directory: directory,
      authorization:
          NoteAuthorizationService(store: KnowledgePolicyStore.memory()),
    );
    review = KnowledgeTypeReview(snapshots: snapshots);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('agent proposal retries retain identity and wait for human acceptance',
      () async {
    final documents = {'claim.md': document('Guidance')};
    final proposal = await withKnowledgePrincipal(
      agent,
      () => review.propose(documents, idempotencyKey: 'task-1'),
    );
    final retry = await withKnowledgePrincipal(
      agent,
      () => review.propose(documents, idempotencyKey: 'task-1'),
    );
    expect(retry.id, proposal.id);
    expect(proposal.state, 'pending');
    await expectLater(
      withKnowledgePrincipal(
        agent,
        () => review.accept(proposal.id, expectedRecordRevision: 1),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      expect(await snapshots.definitions(), isEmpty);
      final accepted =
          await review.accept(proposal.id, expectedRecordRevision: 1);
      expect(accepted.state, 'accepted');
      final restored = KnowledgeTypeReview(snapshots: snapshots);
      expect((await restored.inspect(proposal.id)).state, 'accepted');
      expect(await snapshots.definitions(), hasLength(1));
    });
  });

  test('amendment retains prior candidate and rejects stale review', () async {
    final original = await withKnowledgePrincipal(
      agent,
      () => review.propose(
        {'claim.md': document('Before')},
        idempotencyKey: 'task-1',
      ),
    );
    await withKnowledgePrincipal(
      agent,
      () => review.amend(
        original.id,
        {'claim.md': document('After')},
        expectedRecordRevision: 1,
        expectedProposalRevision: 1,
      ),
    );
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      await expectLater(
        review.accept(original.id, expectedRecordRevision: 1),
        throwsA(isA<ProposalRecordConflictException>()),
      );
      final record = await review.inspect(original.id);
      expect(record.versions, hasLength(2));
      expect(
        record.versions.first.candidate['documents'],
        {'claim.md': document('Before')},
      );
    });
  });
}
