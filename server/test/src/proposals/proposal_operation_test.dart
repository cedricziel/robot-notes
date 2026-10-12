import 'package:server/src/proposals/proposal_operation.dart';
import 'package:test/test.dart';

void main() {
  test('replacement preserves exact Markdown including CRLF and whitespace',
      () {
    final operation = ProposalOperation.fromJson({
      'type': 'replace',
      'block_id': 'block-one',
      'expected_revision': 2,
      'text': '  exact\r\n\r\n',
    });

    expect(operation.text, '  exact\r\n\r\n');
    expect(operation.toJson()['expected_revision'], 2);
  });

  test('evidence-only attachments preserve typed unverified lineage', () {
    final operation = ProposalOperation.fromJson({
      'type': 'attach_evidence',
      'block_id': 'block-one',
      'expected_revision': 2,
      'evidence_refs': [
        {'kind': 'conversation', 'session_id': 'session'},
      ],
    });

    expect(operation.evidenceRefs.single.kind, 'conversation');
    expect(operation.text, isNull);
  });

  test('whole-note deletion cannot be mixed with partial changes', () {
    expect(
      () => ProposalOperation.parseAll([
        {'type': 'delete_note'},
        {'type': 'delete', 'block_id': 'block', 'expected_revision': 1},
      ]),
      throwsFormatException,
    );
  });

  test('caller accepted flags cannot override review', () {
    expect(
      () => ProposalOperation.fromJson({
        'type': 'delete_note',
        'accepted': true,
      }),
      throwsFormatException,
    );
  });

  test('contradictory replacements for one block are rejected together', () {
    expect(
      () => ProposalOperation.parseAll([
        {
          'type': 'replace',
          'block_id': 'block',
          'expected_revision': 1,
          'text': 'one',
        },
        {
          'type': 'replace',
          'block_id': 'block',
          'expected_revision': 1,
          'text': 'two',
        },
      ]),
      throwsFormatException,
    );
  });

  test('deleted anchors cannot also receive evidence or inserted content', () {
    expect(
      () => ProposalOperation.parseAll([
        {'type': 'delete', 'block_id': 'block', 'expected_revision': 1},
        {
          'type': 'insert_after',
          'block_id': 'block',
          'expected_revision': 1,
          'text': '\nnew',
        },
      ]),
      throwsFormatException,
    );
  });

  test('an empty document insertion has no fabricated block revision', () {
    final operation = ProposalOperation.fromJson({
      'type': 'insert_after',
      'block_id': null,
      'expected_revision': null,
      'text': 'first',
    });

    expect(operation.blockId, isNull);
    expect(operation.expectedRevision, isNull);
  });

  test('supersession cannot name an unknown or conversation source', () {
    expect(
      () => ProposalOperation.fromJson({
        'type': 'attach_evidence',
        'block_id': 'block',
        'expected_revision': 1,
        'evidence_refs': [
          {'kind': 'unknown', 'reason': 'source_not_recorded'},
        ],
        'supersedes': [
          {'kind': 'conversation', 'session_id': 'session'},
        ],
      }),
      throwsFormatException,
    );
  });
}
