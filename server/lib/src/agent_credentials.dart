import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:server/src/clock.dart';
import 'package:server/src/oauth/metadata.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/store_support.dart';

/// Ordinary note access and proposal submission, without approval authority.
const Set<String> kDefaultAgentScopes = {
  'notes:read',
  'notes:write',
  kScopeKnowledgePropose,
};

/// A server-issued identity; the raw bearer secret is never persisted.
class AgentCredential {
  /// Restores a provisioned identity and freezes its permission sets.
  AgentCredential({
    required this.id,
    required this.secretHash,
    required this.actor,
    required Set<String> scopes,
    required Set<String> vaultIds,
    required this.createdAt,
    this.revokedAt,
  })  : scopes = Set.unmodifiable(scopes),
        vaultIds = Set.unmodifiable(vaultIds);

  /// Reads a durable record; malformed records throw.
  factory AgentCredential.fromJson(Map<String, dynamic> json) =>
      AgentCredential(
        id: json['id'] as String,
        secretHash: json['secret_hash'] as String,
        actor: json['actor'] as String,
        scopes: (json['scopes'] as List<dynamic>).cast<String>().toSet(),
        vaultIds: (json['vault_ids'] as List<dynamic>).cast<String>().toSet(),
        createdAt: DateTime.parse(json['created_at'] as String),
        revokedAt: json['revoked_at'] == null
            ? null
            : DateTime.parse(json['revoked_at'] as String),
      );

  /// Immutable identity across requests and restarts.
  final String id;

  /// SHA-256 digest of the bearer secret.
  final String secretHash;

  /// Server-recorded display attribution.
  final String actor;

  /// Permissions explicitly granted when provisioned.
  final Set<String> scopes;

  /// Vaults explicitly granted when provisioned.
  final Set<String> vaultIds;

  /// UTC provisioning timestamp.
  final DateTime createdAt;

  /// UTC revocation timestamp; null while usable.
  final DateTime? revokedAt;

  /// Operator listing without raw secrets or their hashes.
  Map<String, Object?> summary() => {
        'id': id,
        'actor': actor,
        'scopes': scopes.toList()..sort(),
        'vault_ids': vaultIds.toList()..sort(),
        'created_at': createdAt.toIso8601String(),
        'revoked_at': revokedAt?.toIso8601String(),
      };

  /// Durable representation, including only the hashed secret.
  Map<String, dynamic> toJson() => {...summary(), 'secret_hash': secretHash};
}

/// Durable credential provisioning and revocation outside editable content.
class AgentCredentialStore {
  /// Opens a credential directory outside editable vault content.
  AgentCredentialStore({
    required this.dir,
    Clock clock = const Clock(),
    Random? random,
  })  : _clock = clock,
        _random = random ?? Random.secure();

  /// Durable storage directory.
  final Directory dir;
  final Clock _clock;
  final Random _random;
  final KeyedMutex _mutex = KeyedMutex();
  final _revocations = StreamController<String>.broadcast(sync: true);

  /// Emitted after durable revocation so live connections can disconnect.
  Stream<String> get revocations => _revocations.stream;

  /// Releases live revocation subscriptions when the server stops.
  Future<void> dispose() => _revocations.close();

  /// Returns a secret once after persisting its record; invalid grants throw.
  Future<({String secret, AgentCredential record})> issue({
    required String actor,
    Set<String> scopes = kDefaultAgentScopes,
    Set<String> vaultIds = const {'default'},
  }) =>
      _mutex.run('credentials', () async {
        if (actor.trim().isEmpty ||
            scopes.isEmpty ||
            !scopes.every(kOAuthScopes.contains) ||
            vaultIds.isEmpty) {
          throw ArgumentError('Invalid credential actor, scopes, or vaults');
        }
        final secret = 'rn_agent_${generateRandomToken(_random, 32)}';
        final record = AgentCredential(
          id: generateRandomToken(_random, 16),
          secretHash: hashSecret(secret),
          actor: actor.trim(),
          scopes: scopes,
          vaultIds: vaultIds,
          createdAt: _clock.nowUtc(),
        );
        await atomicWriteJsonFile(_file(record.secretHash), record.toJson());
        return (secret: secret, record: record);
      });

  /// Rejects unknown, malformed, and revoked credentials.
  Future<AgentCredential?> lookup(String secret) async {
    if (!secret.startsWith('rn_agent_')) return null;
    final file = _file(hashSecret(secret));
    if (!file.existsSync()) return null;
    try {
      final record = await _read(file);
      return record.revokedAt == null && record.secretHash == hashSecret(secret)
          ? record
          : null;
    } on Object {
      return null;
    }
  }

  /// Lists durable records, including revocations, without malformed files.
  Future<List<AgentCredential>> list() async {
    if (!dir.existsSync()) return [];
    final records = <AgentCredential>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        records.add(await _read(entity));
      } on Object {
        continue;
      }
    }
    return records..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// Revokes an identity durably; returns false when the ID does not exist.
  Future<bool> revoke(String id) => _mutex.run('credentials', () async {
        for (final record in await list()) {
          if (record.id != id) continue;
          if (record.revokedAt == null) {
            await atomicWriteJsonFile(_file(record.secretHash), {
              ...record.toJson(),
              'revoked_at': _clock.nowUtc().toIso8601String(),
            });
            _revocations.add(record.id);
          }
          return true;
        }
        return false;
      });

  File _file(String hash) => File('${dir.path}/$hash.json');
  Future<AgentCredential> _read(File file) async => AgentCredential.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
}
