import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/oauth_records.dart';
import 'package:server/src/oauth/store_support.dart';

/// Number of bytes of randomness in a minted authorization code. 32 bytes
/// = 256 bits.
const int kAuthorizationCodeBytes = 32;

/// Thrown by [CodeStore.consume] when the presented code does not match
/// any persisted record, or matches one that has expired.
@immutable
class CodeNotFoundException implements Exception {
  /// Creates the exception.
  const CodeNotFoundException();

  @override
  String toString() => 'CodeNotFoundException()';
}

/// Thrown by [CodeStore.consume] when the presented code was already
/// exchanged. Callers SHALL revoke every token minted from [grantId], per
/// the OAuth 2.1 authorization-code-reuse requirement.
@immutable
class CodeReusedException implements Exception {
  /// Creates the exception for the grant the reused code belongs to.
  const CodeReusedException(this.grantId);

  /// Grant family the reused code belongs to.
  final String grantId;

  @override
  String toString() => 'CodeReusedException($grantId)';
}

/// Filesystem-backed store of single-use PKCE authorization codes.
///
/// On-disk layout: each code lives at `<dir>/<sha256(code)>.json`,
/// following the same tmp+fsync+rename and per-key mutex pattern as
/// `InviteStore`. Only the SHA-256 hash of the raw code is ever written.
class CodeStore {
  /// Constructs a store rooted at [dir] (created on first write). [clock]
  /// stamps mint/consume time. [random] supplies the entropy for minted
  /// codes; tests inject a deterministic source.
  CodeStore({
    required this.dir,
    Clock clock = const Clock(),
    Random? random,
    Logger? logger,
  })  : _clock = clock,
        _random = random ?? Random.secure(),
        _log = logger ?? Logger('oauth.code_store');

  /// Authorization codes are valid for 10 minutes from mint.
  static const codeTtl = Duration(minutes: 10);

  /// Filesystem directory holding `*.json` code files.
  final Directory dir;

  final Clock _clock;
  final Random _random;
  final Logger _log;
  final _mutex = KeyedMutex();

  /// Mints a code bound to the given consent, persists its hash, and
  /// returns the raw code (never persisted).
  Future<String> mint({
    required String clientId,
    required String redirectUri,
    required String codeChallenge,
    required Set<String> scopes,
    required String resource,
    required String actor,
    required String grantId,
  }) async {
    final raw = generateRandomToken(_random, kAuthorizationCodeBytes);
    final hash = hashSecret(raw);
    final now = _clock.nowUtc();
    final record = AuthorizationCode(
      codeHash: hash,
      clientId: clientId,
      redirectUri: redirectUri,
      codeChallenge: codeChallenge,
      scopes: scopes,
      resource: resource,
      actor: actor,
      grantId: grantId,
      createdAt: now,
      expiresAt: now.add(codeTtl),
    );
    await _mutex.run(hash, () => _write(record));
    return raw;
  }

  /// Marks [rawCode] as consumed and returns the record.
  ///
  /// Throws [CodeNotFoundException] when the code is unknown or expired,
  /// and [CodeReusedException] when it has already been consumed —
  /// checked before expiry so a reused code is always caught even once
  /// its TTL has since passed.
  Future<AuthorizationCode> consume(String rawCode) {
    final hash = hashSecret(rawCode);
    return _mutex.run(hash, () async {
      final file = _fileFor(hash);
      if (!file.existsSync()) throw const CodeNotFoundException();
      AuthorizationCode record;
      try {
        record = await _readFile(file);
      } on Exception catch (e) {
        _log.warning('Skipping malformed OAuth code ${file.path}: $e');
        throw const CodeNotFoundException();
      }
      if (record.consumedAt != null) {
        throw CodeReusedException(record.grantId);
      }
      final now = _clock.nowUtc();
      if (record.isExpired(now)) throw const CodeNotFoundException();
      final consumed = record.consumedCopy(now);
      await _write(consumed);
      return consumed;
    });
  }

  /// Deletes every code file whose expiry has passed. Returns the count
  /// removed.
  Future<int> purgeExpired() async {
    if (!dir.existsSync()) return 0;
    final now = _clock.nowUtc();
    var purged = 0;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      AuthorizationCode record;
      try {
        record = await _readFile(entity);
      } on Exception catch (e) {
        _log.warning('Skipping malformed OAuth code ${entity.path}: $e');
        continue;
      }
      if (record.isExpired(now)) {
        await entity.delete();
        purged++;
      }
    }
    return purged;
  }

  File _fileFor(String hash) => File('${dir.path}/$hash.json');

  Future<AuthorizationCode> _readFile(File file) async {
    final raw = await file.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return AuthorizationCode.fromJson(json);
  }

  Future<void> _write(AuthorizationCode record) =>
      atomicWriteJsonFile(_fileFor(record.codeHash), record.toJson());
}
