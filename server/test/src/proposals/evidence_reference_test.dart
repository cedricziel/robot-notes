import 'package:server/src/proposals/evidence_reference.dart';
import 'package:test/test.dart';

void main() {
  test('preserves conversation lineage without claiming retrieved proof', () {
    final reference = EvidenceReference.fromJson({
      'kind': 'conversation',
      'session_id': 'session-one',
      'turn_id': 'turn-two',
      'tool_call_id': 'tool-three',
      'task_id': 'task-four',
    });

    expect(reference.toJson(), {
      'kind': 'conversation',
      'session_id': 'session-one',
      'turn_id': 'turn-two',
      'tool_call_id': 'tool-three',
      'task_id': 'task-four',
    });
    expect(reference.requiresResolution, isFalse);
  });

  test('unknown sources remain explicitly unknown', () {
    final reference = EvidenceReference.fromJson({
      'kind': 'unknown',
      'reason': 'source_not_recorded',
    });

    expect(reference.toJson(), {
      'kind': 'unknown',
      'reason': 'source_not_recorded',
    });
    expect(reference.requiresResolution, isFalse);
  });

  test('accepted block refs retain exact immutable source coordinates', () {
    final reference = EvidenceReference.fromJson({
      'kind': 'block_revision',
      'note_id': 'note-one',
      'version': 3,
      'block_id': 'block-two',
      'block_revision': 2,
    });

    expect(reference.noteId, 'note-one');
    expect(reference.noteVersion, 3);
    expect(reference.blockId, 'block-two');
    expect(reference.blockRevision, 2);
    expect(reference.requiresResolution, isTrue);
  });

  test(
    'explicit archive digests require resolution rather than proof flags',
    () {
      final digest = 'a' * 64;
      final reference = EvidenceReference.fromJson({
        'kind': 'archive',
        'digest': digest,
      });

      expect(reference.digest, digest);
      expect(reference.requiresResolution, isTrue);
    },
  );

  test('caller verified flags cannot manufacture trusted evidence', () {
    expect(
      () => EvidenceReference.fromJson({
        'kind': 'unknown',
        'reason': 'source_not_recorded',
        'verified': true,
      }),
      throwsFormatException,
    );
  });

  test('zero block revisions cannot name accepted evidence', () {
    expect(
      () => EvidenceReference.fromJson({
        'kind': 'block_revision',
        'note_id': 'note',
        'version': 1,
        'block_id': 'block',
        'block_revision': 0,
      }),
      throwsFormatException,
    );
  });

  test('arbitrary script schemes are rejected as external source links', () {
    expect(
      () => EvidenceReference.fromJson({
        'kind': 'url',
        'url': 'javascript:run()',
      }),
      throwsFormatException,
    );
  });

  test(
    'cross-vault evidence cannot override the authenticated selected vault',
    () {
      expect(
        () => EvidenceReference.fromJson({
          'kind': 'note_revision',
          'note_id': 'note',
          'version': 1,
          'vault_id': 'another-vault',
        }),
        throwsFormatException,
      );
    },
  );
}
