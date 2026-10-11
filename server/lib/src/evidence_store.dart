import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:server/src/clock.dart';
import 'package:sqlite3/sqlite3.dart';

/// Immutable evidence snapshots, isolated from accepted notes and search.
class EvidenceStore {
  /// Opens a durable per-vault store and removes expired payloads.
  EvidenceStore({
    required File file,
    this.clock = const Clock(),
    Duration? sweepInterval,
  }) {
    file.parent.createSync(recursive: true);
    _db = sqlite3.open(file.path);
    _db
      ..execute('PRAGMA journal_mode = DELETE')
      ..execute('PRAGMA synchronous = FULL')
      ..execute('PRAGMA secure_delete = ON')
      ..execute('''
      CREATE TABLE IF NOT EXISTS evidence (
        id TEXT PRIMARY KEY,
        payload TEXT,
        lineage TEXT,
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      )
    ''');
    _expire();
    if (sweepInterval != null) {
      _sweep = Timer.periodic(sweepInterval, (_) => _expire());
    }
  }

  /// Time source for retention boundaries.
  final Clock clock;
  late final Database _db;
  Timer? _sweep;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');

  void _expire() => _db.execute(
        'UPDATE evidence SET payload = NULL, lineage = NULL '
        'WHERE expires_at <= ? AND payload IS NOT NULL',
        [clock.nowUtc().toIso8601String()],
      );

  /// Commits a snapshot before returning. Retries preserve original metadata.
  /// Throws [FormatException] for invalid snapshots or retention values.
  Map<String, Object?> put(
    String id,
    String payload, {
    required int retentionDays,
    Map<String, dynamic> lineage = const {},
  }) {
    if (!_digest.hasMatch(id) ||
        sha256.convert(utf8.encode(payload)).toString() != id) {
      throw const FormatException('evidence digest mismatch');
    }
    if (retentionDays < 1 || retentionDays > 3650) {
      throw const FormatException('retention_days must be between 1 and 3650');
    }
    final snapshot = jsonDecode(payload);
    if (snapshot is! Map<String, dynamic> ||
        snapshot['session_id'] is! String ||
        (snapshot['session_id'] as String).isEmpty ||
        !const ['turn', 'checkpoint'].contains(snapshot['kind']) ||
        snapshot['messages'] is! List ||
        (snapshot['messages'] as List).any((message) => message is! Map)) {
      throw const FormatException('invalid evidence snapshot');
    }
    final lineageJson = jsonEncode(lineage);
    _expire();
    final now = clock.nowUtc();
    _db.execute(
      'INSERT OR IGNORE INTO evidence '
      '(id, payload, lineage, created_at, expires_at) VALUES (?, ?, ?, ?, ?)',
      [
        id,
        payload,
        lineageJson,
        now.toIso8601String(),
        now.add(Duration(days: retentionDays)).toIso8601String(),
      ],
    );
    return _record(
      _db.select('SELECT * FROM evidence WHERE id = ?', [id]).single,
    );
  }

  Map<String, Object?> _record(Row row) => {
        'id': row['id'],
        'payload': row['payload'],
        'lineage': row['lineage'] == null
            ? null
            : jsonDecode(row['lineage'] as String),
        'created_at': row['created_at'],
        'expires_at': row['expires_at'],
      };

  /// Returns an unexpired snapshot or null after expiry or purge.
  Map<String, Object?>? read(String id) {
    _expire();
    final rows = _db.select(
      'SELECT * FROM evidence WHERE id = ? AND payload IS NOT NULL',
      [id],
    );
    return rows.isEmpty ? null : _record(rows.single);
  }

  /// Purges content and keeps a digest tombstone to reject delayed retries.
  void delete(String id) => _db.execute(
        'UPDATE evidence SET payload = NULL, lineage = NULL WHERE id = ?',
        [id],
      );

  /// Releases the database handle.
  void close() {
    _sweep?.cancel();
    _db.close();
  }
}
