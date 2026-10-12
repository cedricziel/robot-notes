import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/knowledge/extraction_jobs.dart';
import 'package:test/test.dart';

class MovingClock implements Clock {
  DateTime now = DateTime.utc(2026, 10, 12);
  @override
  DateTime nowUtc() => now;
}

void main() {
  test('queued turns coalesce without losing distinct source revisions',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('extraction-turns-');
    final jobs =
        KnowledgeExtractionJobs(file: File('${directory.path}/jobs.db'));
    try {
      String enqueue(String id) => jobs.enqueue(
            id: id,
            sourceId: id,
            revision: 'revision-$id',
            scopeId: 'scope',
            originId: 'operator',
            generation: 'initial',
            coalesceKey: 'conversation',
            config: {
              'source': {'id': id, 'revision': 'revision-$id'},
            },
          );
      expect(enqueue('first'), 'first');
      expect(enqueue('second'), 'first');
      expect(enqueue('second'), 'first');
      final job = jobs.claim()!;
      expect((job['config'] as Map)['sources'], [
        {'id': 'first', 'revision': 'revision-first'},
        {'id': 'second', 'revision': 'revision-second'},
      ]);
      expect(enqueue('third'), 'third');
      jobs.finish('first', job['lease_owner'] as String, 'completed');
      expect(jobs.claim()!['id'], 'third');
    } finally {
      jobs.close();
      await directory.delete(recursive: true);
    }
  });

  test('expired leases recover checkpoints and stable proposal receipts',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('extraction-leases-');
    final clock = MovingClock();
    final jobs = KnowledgeExtractionJobs(
      file: File('${directory.path}/jobs.db'),
      clock: clock,
    );
    try {
      jobs.enqueue(
        id: 'job',
        sourceId: 'source',
        revision: 'revision',
        scopeId: 'scope',
        originId: 'operator',
        generation: 'initial',
        config: {},
      );
      final first = jobs.claim(lease: const Duration(seconds: 5))!;
      expect(jobs.claim(), isNull);
      jobs.checkpoint('job', first['lease_owner'] as String, {
        'offset': 12,
        'submitted': [
          {'proposal_id': 'proposal'},
        ],
        'pending': null,
      });
      clock.now = clock.now.add(const Duration(minutes: 3));
      final recovered = jobs.claim()!;
      expect(recovered['checkpoint'], containsPair('offset', 12));
      expect(recovered['lease_owner'], isNot(first['lease_owner']));
      expect(
        jobs.checkpoint('job', first['lease_owner'] as String, {}),
        isFalse,
      );
      jobs.finish('job', recovered['lease_owner'] as String, 'completed');
      expect(jobs.summaries().single['proposals'], [
        {'proposal_id': 'proposal'},
      ]);
    } finally {
      jobs.close();
      await directory.delete(recursive: true);
    }
  });
}
