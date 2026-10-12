import 'package:server/src/proposals/proposal_record.dart';
import 'package:test/test.dart';

const _author = ProposalAuthor(
  principalId: 'agent:writer',
  label: 'Writer',
  kind: 'agent',
);
const _reviewer = ProposalAuthor(
  principalId: 'oauth:reviewer',
  label: 'Reviewer',
  kind: 'oauth',
);
final _at = DateTime.utc(2026, 10, 11);

ProposalRecord _pending() => ProposalRecord.create(
      id: 'proposal-one',
      noteId: 'note-one',
      author: _author,
      at: _at,
      candidate: const {
        'base_version': 1,
        'operations': [
          {
            'type': 'replace',
            'block_id': 'block',
            'expected_revision': 1,
            'text': 'first',
          }
        ],
        'evidence_refs': [
          {'kind': 'unknown', 'reason': 'source_not_recorded'},
        ],
        'policy_revision': 1,
        'policy_fingerprint': 'policy-one',
      },
    );

void main() {
  test('amendment retains earlier candidate and prior comments', () {
    final original = _pending().comment(
      expectedRecordRevision: 1,
      author: _reviewer,
      body: 'Please revise',
      at: _at,
      commentId: 'comment-one',
      blockId: 'block',
      blockRevision: 1,
    );

    final amended = original.amend(
      expectedRecordRevision: 2,
      expectedProposalRevision: 1,
      author: _author,
      at: _at,
      candidate: const {
        'base_version': 2,
        'operations': [
          {
            'type': 'replace',
            'block_id': 'block',
            'expected_revision': 2,
            'text': 'second',
          }
        ],
        'evidence_refs': [
          {'kind': 'unknown', 'reason': 'source_not_recorded'},
        ],
        'policy_revision': 2,
        'policy_fingerprint': 'policy-two',
      },
    );

    expect(amended.proposalRevision, 2);
    expect(amended.recordRevision, 3);
    expect(amended.versions.first.candidate['base_version'], 1);
    expect(amended.versions.last.candidate['base_version'], 2);
    expect(amended.comments.single['proposal_revision'], 1);
    expect(original.proposalRevision, 1);
  });

  test('stale review revisions cannot overwrite newer activity', () {
    final current = _pending().comment(
      expectedRecordRevision: 1,
      author: _author,
      body: 'Context',
      at: _at,
      commentId: 'comment-one',
    );

    expect(
      () => current.decide(
        expectedRecordRevision: 1,
        author: _reviewer,
        decision: 'deny',
        at: _at,
      ),
      throwsA(isA<ProposalRecordConflictException>()),
    );
  });

  test('a candidate amendment invalidates a requested-changes decision', () {
    final reviewed = _pending().decide(
      expectedRecordRevision: 1,
      author: _reviewer,
      decision: 'request_changes',
      at: _at,
    );

    final amended = reviewed.amend(
      expectedRecordRevision: 2,
      expectedProposalRevision: 1,
      author: _author,
      at: _at,
      candidate: reviewed.current.candidate,
    );

    expect(reviewed.state, 'changes_requested');
    expect(amended.state, 'pending');
    expect(
      amended.events.map((e) => e['type']),
      ['submitted', 'request_changes', 'amended'],
    );
  });

  test('denied proposals retain audit history and cannot be amended', () {
    final denied = _pending().decide(
      expectedRecordRevision: 1,
      author: _reviewer,
      decision: 'deny',
      at: _at,
    );

    expect(
      () => denied.amend(
        expectedRecordRevision: 2,
        expectedProposalRevision: 1,
        author: _author,
        at: _at,
        candidate: denied.current.candidate,
      ),
      throwsA(isA<ProposalRecordConflictException>()),
    );
    expect(denied.state, 'denied');
    expect(denied.events, hasLength(2));
  });

  test('plain approval cannot claim accepted publication', () {
    expect(
      () => _pending().decide(
        expectedRecordRevision: 1,
        author: _reviewer,
        decision: 'approve',
        at: _at,
      ),
      throwsArgumentError,
    );
  });

  test('comment replies must belong to an existing thread in the record', () {
    expect(
      () => _pending().comment(
        expectedRecordRevision: 1,
        author: _author,
        body: 'reply',
        at: _at,
        commentId: 'comment-one',
        replyTo: 'foreign-comment',
      ),
      throwsFormatException,
    );
  });

  test('stored round trip preserves immutable revisions and trusted author ID',
      () {
    final original = _pending().comment(
      expectedRecordRevision: 1,
      author: _reviewer,
      body: 'Context',
      at: _at,
      commentId: 'comment-one',
    );

    final restored = ProposalRecord.fromStoredJson(original.toStoredJson());

    expect(restored.toStoredJson(), original.toStoredJson());
    expect(restored.author.principalId, 'agent:writer');
    expect(restored.summary()['author_label'], 'Writer');
    expect(restored.summary()['author_kind'], 'agent');
  });
  test('candidate fields cannot override the server record envelope', () {
    final record = ProposalRecord.create(
      id: 'real',
      noteId: 'note',
      author: _author,
      at: _at,
      candidate: const {'state': 'accepted', 'proposal_id': 'fake'},
    );
    expect(record.inspect()['state'], 'pending');
    expect(record.inspect()['proposal_id'], 'real');
  });

  test('stored acceptance requires a real accepted version', () {
    final stored = _pending().toStoredJson()..['state'] = 'accepted';
    expect(() => ProposalRecord.fromStoredJson(stored), throwsFormatException);
  });
}
