import 'dart:convert';
import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:ulid/ulid.dart';

/// Durable leases, checkpoints, proposal receipts, and overlap fingerprints.
class KnowledgeExtractionJobs {
  /// Creates a vault-local scheduler without starting a worker or reading
  /// sources.
  KnowledgeExtractionJobs({required File file, this.clock = const Clock()}) {
    file.parent.createSync(recursive: true);
    _db = sqlite3.open(file.path);
    _db
      ..execute('PRAGMA synchronous = FULL')
      ..execute('PRAGMA secure_delete = ON')
      ..execute(
        'CREATE TABLE IF NOT EXISTS extraction_jobs (id TEXT '
        'PRIMARY KEY, source_id TEXT NOT NULL, source_revision '
        'TEXT NOT NULL, scope_id TEXT NOT NULL, origin_id TEXT '
        'NOT NULL, generation TEXT NOT NULL, config TEXT NOT '
        'NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL '
        'DEFAULT 0, not_before INTEGER NOT NULL DEFAULT 0, '
        'lease_owner TEXT, lease_until INTEGER NOT NULL DEFAULT '
        '0, checkpoint TEXT NOT NULL, diagnostic TEXT)',
      )
      ..execute(
        'CREATE TABLE IF NOT EXISTS extraction_observations (id '
        'TEXT PRIMARY KEY, job_id TEXT NOT NULL)',
      )
      ..execute(
        'CREATE TABLE IF NOT EXISTS extraction_fingerprints '
        '(namespace TEXT NOT NULL, fingerprint TEXT NOT NULL, '
        'receipt TEXT NOT NULL, PRIMARY KEY(namespace, '
        'fingerprint))',
      );
  }

  /// Injectable scheduler time for deterministic lease recovery tests.
  final Clock clock;
  late final Database _db;

  /// Idempotently schedules one pinned source revision and extractor
  /// generation.
  String enqueue({
    required String id,
    required String sourceId,
    required String revision,
    required String scopeId,
    required String originId,
    required String generation,
    required Map<String, Object?> config,
    String? coalesceKey,
    int startingOffset = 0,
  }) {
    if (startingOffset < 0) {
      throw const FormatException('Invalid extraction checkpoint');
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      final retained = _db.select(
        'SELECT job_id FROM extraction_observations WHERE id = ?',
        [id],
      );
      if (retained.isNotEmpty) {
        _db.execute('COMMIT');
        return retained.single['job_id'] as String;
      }
      final candidates = coalesceKey == null
          ? <Row>[]
          : _db.select(
              'SELECT id, config FROM extraction_jobs WHERE state = '
              r"'queued' AND json_extract(config, '$.coalesce_key') = "
              '? ORDER BY rowid LIMIT 1',
              [coalesceKey],
            );
      var jobId = id;
      if (candidates.isNotEmpty &&
          ((jsonDecode(candidates.single['config'] as String)
                      as Map<String, dynamic>)['sources'] as List<dynamic>)
                  .length <
              50) {
        jobId = candidates.single['id'] as String;
        final current = jsonDecode(candidates.single['config'] as String)
            as Map<String, dynamic>;
        (current['sources'] as List<dynamic>).add(config['source']);
        _db.execute(
          'UPDATE extraction_jobs SET config = ? WHERE id = ?',
          [jsonEncode(current), jobId],
        );
      } else {
        final frozen = {
          ...config,
          'sources': [config['source']],
          'coalesce_key': coalesceKey,
        };
        _db.execute(
            'INSERT OR IGNORE INTO extraction_jobs(id, source_id, '
            'source_revision, scope_id, origin_id, generation, '
            'config, state, checkpoint) VALUES (?, ?, ?, ?, ?, ?, '
            '?, ?, ?)',
            [
              id,
              sourceId,
              revision,
              scopeId,
              originId,
              generation,
              jsonEncode(frozen),
              'queued',
              jsonEncode({
                'source_index': 0,
                'offset': startingOffset,
                'chunks': 0,
                'pending': null,
                'submitted': <Object?>[],
              }),
            ]);
      }
      _db
        ..execute(
          'INSERT INTO extraction_observations(id, job_id) VALUES (?, ?)',
          [id, jobId],
        )
        ..execute('COMMIT');
      return jobId;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Claims queued work or an expired lease without resetting durable progress.
  Map<String, dynamic>? claim({Duration lease = const Duration(minutes: 2)}) {
    final now = clock.nowUtc().millisecondsSinceEpoch;
    _db.execute('BEGIN IMMEDIATE');
    try {
      final rows = _db.select(
        'SELECT * FROM extraction_jobs WHERE (state IN '
        "('queued','retry_wait') AND not_before <= ?) OR (state "
        "= 'running' AND lease_until <= ?) ORDER BY rowid LIMIT "
        '1',
        [now, now],
      );
      if (rows.isEmpty) {
        _db.execute('COMMIT');
        return null;
      }
      final owner = Ulid().toString();
      final row = rows.single;
      _db
        ..execute(
          "UPDATE extraction_jobs SET state = 'running', attempts "
          '= attempts + 1, lease_owner = ?, lease_until = ? WHERE '
          'id = ?',
          [owner, now + lease.inMilliseconds, row['id']],
        )
        ..execute('COMMIT');
      return {
        ...row,
        'state': 'running',
        'attempts': (row['attempts'] as int) + 1,
        'lease_owner': owner,
        'config': jsonDecode(row['config'] as String),
        'checkpoint': jsonDecode(row['checkpoint'] as String),
      };
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Saves progress only while this worker still owns its active lease.
  bool checkpoint(
    String id,
    String owner,
    Map<String, Object?> checkpoint, {
    Duration lease = const Duration(minutes: 2),
  }) {
    _db.execute(
        'UPDATE extraction_jobs SET checkpoint = ?, lease_until '
        "= ? WHERE id = ? AND state = 'running' AND lease_owner "
        '= ?',
        [
          jsonEncode(checkpoint),
          clock.nowUtc().add(lease).millisecondsSinceEpoch,
          id,
          owner,
        ]);
    return _db.updatedRows == 1;
  }

  /// Ends an owned attempt with a safe category and optional bounded retry
  /// delay.
  void finish(
    String id,
    String owner,
    String state, {
    String? diagnostic,
    Duration retryAfter = Duration.zero,
  }) {
    if (!const {'completed', 'retry_wait', 'blocked', 'cancelled'}
        .contains(state)) {
      throw const FormatException('Invalid extraction job state');
    }
    _db.execute(
        'UPDATE extraction_jobs SET state = ?, diagnostic = ?, '
        'lease_owner = NULL, lease_until = 0, not_before = ? '
        'WHERE id = ? AND state = ? AND lease_owner = ?',
        [
          state,
          diagnostic,
          clock.nowUtc().add(retryAfter).millisecondsSinceEpoch,
          id,
          'running',
          owner,
        ]);
  }

  /// Retrieves only scheduler metadata; model inputs and pending prose stay
  /// private.
  List<Map<String, Object?>> summaries() => [
        for (final row in _db.select(
          'SELECT id, source_id, source_revision, scope_id, '
          'origin_id, state, attempts, diagnostic, checkpoint '
          'FROM extraction_jobs',
        ))
          {
            'id': row['id'],
            'source_id': row['source_id'],
            'source_revision': row['source_revision'],
            'scope_id': row['scope_id'],
            'origin_id': row['origin_id'],
            'state': row['state'],
            'attempts': row['attempts'],
            'diagnostic': row['diagnostic'],
            'proposals': (jsonDecode(row['checkpoint'] as String)
                as Map<String, dynamic>)['submitted'],
            'next_scalar_offset': (jsonDecode(row['checkpoint'] as String)
                as Map<String, dynamic>)['offset'],
          },
      ];

  /// Cancels disabled or revoked scopes and clears transient source copies.
  void cancelScope(String id) => _db.execute(
        "UPDATE extraction_jobs SET state = 'cancelled', "
        "diagnostic = 'scope_disabled', checkpoint = "
        r"json_set(checkpoint, '$.pending', NULL, "
        r"'$.classifications', json('[]')), lease_owner = NULL "
        "WHERE scope_id = ? AND state != 'completed'",
        [id],
      );

  /// Clears transient copies before source purge, including blocked jobs.
  void purgeSource(String id, String revision) => _db.execute(
        "UPDATE extraction_jobs SET state = 'cancelled', "
        "diagnostic = 'source_unavailable', checkpoint = "
        r"json_set(checkpoint, '$.pending', NULL, "
        r"'$.classifications', json('[]')), lease_owner = NULL "
        'WHERE (source_id = ? AND source_revision = ?) OR '
        'EXISTS (SELECT 1 FROM '
        r"json_each(extraction_jobs.config, '$.sources') AS s "
        r"WHERE json_extract(s.value, '$.id') = ? AND "
        r"json_extract(s.value, '$.revision') = ?)",
        [id, revision, id, revision],
      );

  /// Finds an already persisted proposal from overlapping conversation
  /// triggers.
  Map<String, dynamic>? fingerprint(String namespace, String fingerprint) {
    final rows = _db.select(
      'SELECT receipt FROM extraction_fingerprints WHERE '
      'namespace = ? AND fingerprint = ?',
      [namespace, fingerprint],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['receipt'] as String) as Map<String, dynamic>;
  }

  /// Retains a durable proposal identity before the source checkpoint advances.
  void recordFingerprint(
    String namespace,
    String fingerprint,
    Map<String, Object?> receipt,
  ) =>
      _db.execute(
        'INSERT OR IGNORE INTO '
        'extraction_fingerprints(namespace, fingerprint, '
        'receipt) VALUES (?, ?, ?)',
        [namespace, fingerprint, jsonEncode(receipt)],
      );

  /// Explicitly retries blocked work without inventing a new extractor
  /// generation.
  void retryBlocked(String id) => _db.execute(
        "UPDATE extraction_jobs SET state = 'queued', attempts "
        '= 0, diagnostic = NULL WHERE id = ? AND state = '
        "'blocked'",
        [id],
      );

  /// Releases the scheduler handle after the worker stops.
  void close() => _db.close();
}
