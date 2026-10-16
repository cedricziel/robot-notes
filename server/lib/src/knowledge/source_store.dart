import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/oauth/store_support.dart' show KeyedMutex;
import 'package:sqlite3/sqlite3.dart';
import 'package:ulid/ulid.dart';

/// A delivery key was reused for different bytes, metadata, or requested scope.
class SourceDeliveryConflict implements Exception {}

/// An immutable source revision is absent or explicitly purged.
class SourceUnavailable implements Exception {}

/// Server-derived descriptor for an immutable retained source revision.
class KnowledgeSourceRevision {
  /// Restores descriptor metadata from the trusted source registry.
  KnowledgeSourceRevision.fromJson(Map<String, dynamic> value)
      : id = value['id'] as String,
        revision = value['revision'] as String,
        digest = value['sha256'] as String,
        scopeId = value['scope_id'] as String,
        mediaType = value['media_type'] as String,
        adapter = value['adapter'] as String,
        principalId = value['principal_id'] as String,
        capturedAt = DateTime.parse(value['captured_at'] as String),
        observationKind = value['observation_kind'] as String? ?? 'import',
        conversationId = value['conversation_id'] as String?,
        extractionEligible = value['extraction_eligible'] as bool? ?? false,
        scopeRevision = value['scope_revision'] as int? ?? 0;

  /// Stable source identity, derived independently of source prose.
  final String id;

  /// Immutable byte revision digest.
  final String revision;

  /// Exact original-byte digest, independent of media-type revision identity.
  final String digest;

  /// Stable server-configured scope identity.
  final String scopeId;

  /// Canonical media type.
  final String mediaType;

  /// Exact case-sensitive adapter identifier.
  final String adapter;

  /// Authenticated originating principal, never a payload actor label.
  final String principalId;

  /// Server receipt time, excluded from delivery digests.
  final DateTime capturedAt;

  /// Adapter observation boundary; completed turns are not completed tasks.
  final String observationKind;

  /// Supplied conversation lineage, never inferred from a later session.
  final String? conversationId;

  /// Server-derived eligibility frozen when the source was first ingested.
  final bool extractionEligible;

  /// Scope configuration generation at original ingestion.
  final int scopeRevision;

  /// Descriptor wire format; never includes original source bytes.
  Map<String, dynamic> toJson() => {
        'id': id,
        'revision': revision,
        'sha256': digest,
        'scope_id': scopeId,
        'media_type': mediaType,
        'adapter': adapter,
        'principal_id': principalId,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'observation_kind': observationKind,
        'conversation_id': conversationId,
        'extraction_eligible': extractionEligible,
        'scope_revision': scopeRevision,
      };
}

/// Immutable source blobs and transactionally retained delivery tombstones.
class KnowledgeSourceStore {
  /// Opens one vault-local registry, separate from ordinary recall indexes.
  KnowledgeSourceStore({
    required this.directory,
    required this.authorization,
    this.clock = const Clock(),
    this.maxBytes = 10 * 1024 * 1024,
  }) {
    directory.createSync(recursive: true);
    _db = sqlite3.open('${directory.path}/sources.db');
    _db
      ..execute('PRAGMA synchronous = FULL')
      ..execute(
        'CREATE TABLE IF NOT EXISTS scopes (id TEXT PRIMARY '
        'KEY, config TEXT NOT NULL)',
      )
      ..execute(
        'CREATE TABLE IF NOT EXISTS revisions (source_id TEXT '
        'NOT NULL, revision TEXT NOT NULL, descriptor TEXT NOT '
        'NULL, purged INTEGER NOT NULL DEFAULT 0, PRIMARY '
        'KEY(source_id, revision))',
      )
      ..execute(
        'CREATE TABLE IF NOT EXISTS deliveries (key TEXT '
        'PRIMARY KEY, digest TEXT NOT NULL, source_id TEXT NOT '
        'NULL, revision TEXT NOT NULL, consumed INTEGER NOT '
        'NULL DEFAULT 0)',
      );
    for (final row in _db
        .select('SELECT source_id, revision FROM revisions WHERE purged = 1')) {
      final blob = _blob(row['source_id'] as String, row['revision'] as String);
      if (blob.existsSync()) blob.deleteSync();
    }
  }

  /// Selected vault's retained source directory, never caller-controlled.
  final Directory directory;

  /// Central credential and policy checks.
  final NoteAuthorizationService authorization;

  /// Server timestamp source.
  final Clock clock;

  /// Per-observation bound before persistence or extraction.
  final int maxBytes;
  late final Database _db;
  static final _identity = RegExp(r'^[a-f0-9]{64}$');

  String _hash(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  Map<String, dynamic> _scope(String id) {
    final rows = _db.select('SELECT config FROM scopes WHERE id = ?', [id]);
    if (rows.isEmpty) {
      throw const KnowledgeAccessDeniedException(KnowledgeAction.read);
    }
    final scope =
        jsonDecode(rows.single['config'] as String) as Map<String, dynamic>;
    final principals = (scope['principals'] as List<dynamic>).cast<String>();
    if (currentKnowledgePrincipal.kind != KnowledgePrincipalKind.operator &&
        !principals.contains('*') &&
        !principals.contains(currentKnowledgePrincipal.id)) {
      throw const KnowledgeAccessDeniedException(KnowledgeAction.read);
    }
    return scope;
  }

  void _require(KnowledgeAction action, String scopeId) {
    _scope(scopeId);
    authorization.require(
      currentKnowledgePrincipal,
      action,
      KnowledgeTarget.folder('sources'),
    );
  }

  /// Serializes source-store writers (ingest) among themselves WITHOUT
  /// taking the shared policy mutation lock (issue #427): ingest previously
  /// held that single vault-wide mutex for its whole body, so a slow
  /// ingest queued every `POST /notes` behind it (p95 11.7s) and vice
  /// versa. Delivery dedup stays correct — that state lives entirely in
  /// this store's own SQLite database.
  final KeyedMutex _sourceMutex = KeyedMutex();

  /// Configures stable capture scope access; capture remains disabled by
  /// default.
  Future<void> configureScope(
    String id, {
    required Set<String> captureAdapters,
    required Set<String> principals,
    bool extractionEnabled = false,
    String trigger = 'session_end',
  }) =>
      authorization.store.withMutationLock(() async {
        authorization.require(
          currentKnowledgePrincipal,
          KnowledgeAction.policy,
          KnowledgeTarget.folder('sources'),
        );
        if (id.trim().isEmpty ||
            principals.isEmpty ||
            captureAdapters.any((adapter) => adapter.trim().isEmpty)) {
          throw const FormatException('Invalid capture scope');
        }
        if (!const {'session_end', 'completed_turn', 'both'}
            .contains(trigger)) {
          throw const FormatException('Invalid extraction trigger');
        }
        final adapters = captureAdapters.toList()..sort();
        final allowed = {
          ...principals,
          if (extractionEnabled)
            'agent:server-extraction:${authorization.vaultId}',
        }.toList()
          ..sort();
        final previous =
            _db.select('SELECT config FROM scopes WHERE id = ?', [id]);
        final revision = previous.isEmpty
            ? 1
            : (jsonDecode(previous.single['config'] as String)
                    as Map<String, dynamic>)['revision'] as int? ??
                0;
        _db.execute(
            'INSERT INTO scopes(id, config) VALUES (?, ?) ON '
            'CONFLICT(id) DO UPDATE SET config=excluded.config',
            [
              id,
              jsonEncode({
                'capture_adapters': adapters,
                'principals': allowed,
                'extraction_enabled': extractionEnabled,
                'trigger': trigger,
                'revision': previous.isEmpty ? revision : revision + 1,
              }),
            ]);
        await onScopeChanged?.call(id);
      });

  /// Optional durable scheduling callback; retries reuse the same frozen
  /// source.
  Future<void> Function(KnowledgeSourceRevision source)? onObservation;

  /// Scope changes cancel or stop affected extraction work.
  Future<void> Function(String scopeId)? onScopeChanged;

  /// Clears transient extraction copies before authorized source erasure.
  Future<void> Function(String sourceId, String revision)? onPurge;

  /// Reads only authorized server-owned capture and extraction settings.
  Map<String, dynamic> scopeSettings(String id) {
    _require(KnowledgeAction.read, id);
    return _scope(id);
  }

  /// Rechecks a retained source descriptor under current scope authorization.
  KnowledgeSourceRevision descriptor(String id, String revision) =>
      _descriptor(id, revision);

  String _media(String mediaType) {
    final parts = mediaType.split(';');
    final type = parts.removeAt(0).trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$').hasMatch(type)) {
      throw const FormatException('Invalid media type');
    }
    final parameters = <String, String>{};
    for (final part in parts) {
      final equals = part.indexOf('=');
      if (equals < 1) {
        throw const FormatException('Invalid media type parameter');
      }
      final key = part.substring(0, equals).trim().toLowerCase();
      if (parameters.containsKey(key)) {
        throw const FormatException('Duplicate media parameter');
      }
      parameters[key] = part.substring(equals + 1).trim();
    }
    final names = parameters.keys.toList()..sort();
    return '$type${names.map((name) => ';$name=${parameters[name]}').join()}';
  }

  File _blob(String id, String revision) {
    if (!_identity.hasMatch(id) || !_identity.hasMatch(revision)) {
      throw const FormatException('Invalid source reference');
    }
    return File('${directory.path}/blobs/$id/$revision.bin');
  }

  /// Ingests original bytes; automatic delivery additionally requires adapter
  /// opt-in.
  /// Current authorization and enablement are checked before every retry
  /// lookup.
  Future<KnowledgeSourceRevision> ingest({
    required String adapter,
    required String eventId,
    required String scopeId,
    required List<int> bytes,
    required String mediaType,
    DateTime? observedAt,
    bool automatic = false,
    String? sourceId,
    String observationKind = 'import',
    String? conversationId,
  }) async {
    // Serialization is per source store, NOT the vault-wide policy mutation
    // lock (issue #427): the two write paths were mutually blocking. The
    // [onObservation] callbacks are deliberately invoked AFTER the lock is
    // released — they schedule extraction work (which itself may take the
    // policy lock) and must never run under this mutex.
    final (source, observed) = await _sourceMutex.run('sources', () async {
      _require(KnowledgeAction.propose, scopeId);
      final scope = _scope(scopeId);
      if (automatic &&
          !(scope['capture_adapters'] as List<dynamic>).contains(adapter)) {
        throw const KnowledgeAccessDeniedException(KnowledgeAction.propose);
      }
      if (adapter.trim().isEmpty ||
          eventId.trim().isEmpty ||
          bytes.length > maxBytes) {
        throw const FormatException(
          'Invalid or oversized source observation',
        );
      }
      if (!const {'import', 'completed_turn', 'session_end'}
          .contains(observationKind)) {
        throw const FormatException('Invalid observation kind');
      }
      final media = _media(mediaType);
      final byteDigest = sha256.convert(bytes).toString();
      final revision = _hash([byteDigest, media]);
      final key = _hash([
        authorization.vaultId,
        currentKnowledgePrincipal.id,
        adapter,
        eventId,
      ]);
      final digest = _hash([
        byteDigest,
        media,
        observedAt?.toUtc().toIso8601String(),
        scopeId,
        observationKind,
        conversationId,
      ]);
      final retained =
          _db.select('SELECT * FROM deliveries WHERE key = ?', [key]);
      if (retained.isNotEmpty) {
        final row = retained.single;
        if (row['digest'] != digest ||
            (sourceId != null && sourceId != row['source_id'])) {
          throw SourceDeliveryConflict();
        }
        if (row['consumed'] == 1) throw SourceUnavailable();
        final source = _descriptor(
          row['source_id'] as String,
          row['revision'] as String,
        );
        await _writeDescriptor(source);
        return (source, <KnowledgeSourceRevision>[source]);
      }
      final id = sourceId ?? key;
      if (sourceId != null) {
        final existing = _db.select(
          'SELECT descriptor FROM revisions WHERE source_id = ? '
          'AND purged = 0 LIMIT 1',
          [sourceId],
        );
        if (existing.isEmpty) throw SourceUnavailable();
        final source = KnowledgeSourceRevision.fromJson(
          jsonDecode(existing.single['descriptor'] as String)
              as Map<String, dynamic>,
        );
        _require(KnowledgeAction.propose, source.scopeId);
        if (source.scopeId != scopeId) throw SourceDeliveryConflict();
      }
      final descriptor = KnowledgeSourceRevision.fromJson({
        'id': id,
        'revision': revision,
        'sha256': byteDigest,
        'scope_id': scopeId,
        'media_type': media,
        'adapter': adapter,
        'principal_id': currentKnowledgePrincipal.id,
        'captured_at': clock.nowUtc().toIso8601String(),
        'observation_kind': observationKind,
        'conversation_id': conversationId,
        'scope_revision': scope['revision'] ?? 0,
        'extraction_eligible': scope['extraction_enabled'] == true &&
            (observationKind == 'import' ||
                scope['trigger'] == 'both' ||
                scope['trigger'] == observationKind),
      });
      final blob = _blob(id, revision);
      await blob.parent.create(recursive: true);
      if (blob.existsSync()) {
        if (sha256.convert(await blob.readAsBytes()).toString() != byteDigest) {
          throw const FormatException('Source blob digest mismatch');
        }
      } else {
        await blob.writeAsBytes(bytes, flush: true);
      }
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db
          ..execute(
            'INSERT OR IGNORE INTO revisions(source_id, revision, '
            'descriptor) VALUES (?, ?, ?)',
            [id, revision, jsonEncode(descriptor.toJson())],
          )
          ..execute(
            'INSERT INTO deliveries(key, digest, source_id, '
            'revision) VALUES (?, ?, ?, ?)',
            [key, digest, id, revision],
          )
          ..execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
      await _writeDescriptor(descriptor);
      return (descriptor, <KnowledgeSourceRevision>[descriptor]);
    });
    for (final observedSource in observed) {
      await onObservation?.call(observedSource);
    }
    return source;
  }

  KnowledgeSourceRevision _descriptor(String id, String revision) {
    final rows = _db.select(
      'SELECT descriptor, purged FROM revisions WHERE '
      'source_id = ? AND revision = ?',
      [id, revision],
    );
    if (rows.isEmpty || rows.single['purged'] == 1) throw SourceUnavailable();
    final descriptor = KnowledgeSourceRevision.fromJson(
      jsonDecode(rows.single['descriptor'] as String) as Map<String, dynamic>,
    );
    _require(KnowledgeAction.read, descriptor.scopeId);
    return descriptor;
  }

  Future<void> _writeDescriptor(KnowledgeSourceRevision source) async {
    final file = File(
      '${directory.path}/descriptors/${source.id}/${source.revision}.md',
    );
    await file.parent.create(recursive: true);
    final firstRevision = jsonDecode(
      _db.select(
        'SELECT descriptor FROM revisions WHERE source_id = ? '
        'ORDER BY rowid LIMIT 1',
        [source.id],
      ).single['descriptor'] as String,
    ) as Map<String, dynamic>;
    final markdown = serializeFrontmatter(
      Frontmatter(
        metadata: {
          'id': Ulid.fromBytes(
            sha256.convert(utf8.encode(source.id)).bytes.take(16).toList(),
          ).toString().toLowerCase(),
          'title': 'Source ${source.adapter}',
          'path': 'sources',
          'version': _db.select(
            'SELECT revision FROM revisions WHERE source_id = ? AND '
            'rowid <= (SELECT rowid FROM revisions WHERE source_id '
            '= ? AND revision = ?)',
            [source.id, source.id, source.revision],
          ).length,
          'created_at': firstRevision['captured_at'],
          'updated_at': source.capturedAt.toIso8601String(),
          'knowledge': {
            'format_version': 1,
            'role': 'source',
            'source': {
              ...source.toJson(),
              'sha256': source.digest,
              'blob_ref': '${source.id}/${source.revision}.bin',
            },
          },
        },
        body: 'Original material is retained separately.\n',
      ),
    );
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(markdown, flush: true);
    await temporary.rename(file.path);
    final latest = _db.select(
      'SELECT descriptor FROM revisions WHERE source_id = ? '
      'AND purged = 0 ORDER BY rowid DESC LIMIT 1',
      [source.id],
    );
    if (latest.isNotEmpty) {
      final current = KnowledgeSourceRevision.fromJson(
        jsonDecode(latest.single['descriptor'] as String)
            as Map<String, dynamic>,
      );
      if (current.revision != source.revision) {
        await _writeDescriptor(current);
      } else {
        final canonical = File('${directory.path}/descriptors/${source.id}.md');
        final pending = File('${canonical.path}.tmp');
        await pending.writeAsString(markdown, flush: true);
        await pending.rename(canonical.path);
      }
    }
  }

  /// Explicitly reads original bytes and verifies the exact immutable digest.
  Future<List<int>> inspect(String id, String revision) async {
    final source = _descriptor(id, revision);
    final file = _blob(id, revision);
    if (!file.existsSync()) throw SourceUnavailable();
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != source.digest) {
      throw const FormatException('Source revision digest mismatch');
    }
    if (!File('${directory.path}/descriptors/$id.md').existsSync()) {
      await _writeDescriptor(source);
    }
    return bytes;
  }

  /// Resolves whole text or a nonempty Unicode scalar range in an authorized
  /// revision.
  Future<String> passage(
    String id,
    String revision,
    Map<String, Object?> locator,
  ) async {
    final descriptor = _descriptor(id, revision);
    final bytes = await inspect(id, revision);
    if (locator['kind'] == 'whole_document') {
      return descriptor.mediaType.startsWith('text/') ||
              descriptor.mediaType.startsWith('application/json')
          ? utf8.decode(bytes)
          : '';
    }
    if (locator['kind'] != 'text_range' ||
        !(descriptor.mediaType.startsWith('text/') ||
            descriptor.mediaType.startsWith('application/json')) ||
        locator['start'] is! int ||
        locator['end'] is! int) {
      throw const FormatException('Invalid source locator');
    }
    final scalars = utf8.decode(bytes).runes.toList();
    final start = locator['start']! as int;
    final end = locator['end']! as int;
    if (start < 0 || end <= start || end > scalars.length) {
      throw const FormatException('Source locator out of bounds');
    }
    return String.fromCharCodes(scalars.sublist(start, end));
  }

  /// Enumerates only sources readable under current scope and policy.
  Future<List<KnowledgeSourceRevision>> list() async {
    final result = <KnowledgeSourceRevision>[];
    for (final row in _db
        .select('SELECT source_id, revision FROM revisions WHERE purged = 0')) {
      try {
        result.add(
          _descriptor(row['source_id'] as String, row['revision'] as String),
        );
      } on KnowledgeAccessDeniedException {
        continue;
      }
    }
    return result;
  }

  /// Purges bytes while retaining non-content delivery tombstones.
  Future<void> purge(String id, String revision) =>
      authorization.store.withMutationLock(() async {
        final source = _descriptor(id, revision);
        _require(KnowledgeAction.purge, source.scopeId);
        await onPurge?.call(id, revision);
        _db.execute('BEGIN IMMEDIATE');
        try {
          _db
            ..execute(
              'UPDATE deliveries SET consumed = 1 WHERE source_id = ? '
              'AND revision = ?',
              [id, revision],
            )
            ..execute(
              'UPDATE revisions SET purged = 1, descriptor = ? WHERE '
              'source_id = ? AND revision = ?',
              [jsonEncode(source.toJson()), id, revision],
            )
            ..execute('COMMIT');
        } catch (_) {
          _db.execute('ROLLBACK');
          rethrow;
        }
        final blob = _blob(id, revision);
        if (blob.existsSync()) await blob.delete();
        final descriptor = File('${directory.path}/descriptors/$id.md');
        if (descriptor.existsSync()) await descriptor.delete();
      });

  /// Closes the vault-local source registry.
  void close() => _db.close();
}
