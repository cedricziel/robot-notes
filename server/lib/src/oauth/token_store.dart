import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/oauth_records.dart';
import 'package:server/src/oauth/store_support.dart';

/// Number of bytes of randomness in a minted access or refresh token. 32
/// bytes = 256 bits.
const int kOAuthTokenBytes = 32;

/// Thrown by [TokenStore.rotateRefresh] when the presented refresh token
/// does not match any persisted record, or matches one that has expired.
@immutable
class TokenNotFoundException implements Exception {
  /// Creates the exception.
  const TokenNotFoundException();

  @override
  String toString() => 'TokenNotFoundException()';
}

/// Thrown by [TokenStore.rotateRefresh] when the presented refresh token
/// was already rotated or revoked — a sign the token family has leaked.
/// [TokenStore.rotateRefresh] has already revoked every token of
/// [grantId] by the time this is thrown.
@immutable
class RefreshReuseException implements Exception {
  /// Creates the exception for the grant the reused token belongs to.
  const RefreshReuseException(this.grantId);

  /// Grant family the reused refresh token belongs to.
  final String grantId;

  @override
  String toString() => 'RefreshReuseException($grantId)';
}

/// Thrown by [TokenStore.rotateRefresh] when the requested scopes are not
/// a subset of the grant's existing scopes.
@immutable
class ScopeWideningException implements Exception {
  /// Creates the exception.
  const ScopeWideningException();

  @override
  String toString() => 'ScopeWideningException()';
}

/// A freshly minted access/refresh token pair, in raw (never persisted)
/// form.
@immutable
class IssuedTokens {
  /// Pairs the two raw tokens with the metadata a token response needs.
  const IssuedTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.scopes,
  });

  /// Raw bearer credential for `/mcp`.
  final String accessToken;

  /// Raw credential for the next `/oauth/token` refresh.
  final String refreshToken;

  /// Access-token lifetime in seconds, for the token-response `expires_in`
  /// field.
  final int expiresIn;

  /// Scopes granted to both tokens.
  final Set<String> scopes;
}

/// Filesystem-backed store of hashed OAuth access and refresh tokens.
///
/// On-disk layout: each token lives at `<dir>/<sha256(token)>.json`,
/// following the same tmp+fsync+rename and per-key mutex pattern as
/// `InviteStore`. Only the SHA-256 hash of the raw token is ever written.
/// Every token minted from one consent shares a `grant_id`, so
/// [revokeGrant] can cascade with a single directory scan.
class TokenStore {
  /// Constructs a store rooted at [dir] (created on first write). [clock]
  /// stamps issue/revoke/rotate time. [random] supplies the entropy for
  /// minted tokens; tests inject a deterministic source.
  TokenStore({
    required this.dir,
    Clock clock = const Clock(),
    Random? random,
    Logger? logger,
  })  : _clock = clock,
        _random = random ?? Random.secure(),
        _log = logger ?? Logger('oauth.token_store');

  /// Access tokens are valid for 1 hour from issue.
  static const accessTtl = Duration(hours: 1);

  /// Refresh tokens are valid for 30 days from issue.
  static const refreshTtl = Duration(days: 30);

  /// Filesystem directory holding `*.json` token files.
  final Directory dir;

  final Clock _clock;
  final Random _random;
  final Logger _log;
  final _mutex = KeyedMutex();

  /// Mints a fresh access/refresh pair for [grantId] and persists both as
  /// hashed records sharing the same issue time.
  Future<IssuedTokens> issue({
    required String clientId,
    required String actor,
    required Set<String> scopes,
    required String resource,
    required String grantId,
  }) async {
    final now = _clock.nowUtc();
    final rawAccess = generateRandomToken(_random, kOAuthTokenBytes);
    final rawRefresh = generateRandomToken(_random, kOAuthTokenBytes);
    final access = OAuthToken(
      tokenHash: hashSecret(rawAccess),
      kind: OAuthTokenKind.access,
      clientId: clientId,
      actor: actor,
      scopes: scopes,
      resource: resource,
      grantId: grantId,
      createdAt: now,
      expiresAt: now.add(accessTtl),
    );
    final refresh = OAuthToken(
      tokenHash: hashSecret(rawRefresh),
      kind: OAuthTokenKind.refresh,
      clientId: clientId,
      actor: actor,
      scopes: scopes,
      resource: resource,
      grantId: grantId,
      createdAt: now,
      expiresAt: now.add(refreshTtl),
    );
    await _mutex.run(access.tokenHash, () => _write(access));
    await _mutex.run(refresh.tokenHash, () => _write(refresh));
    return IssuedTokens(
      accessToken: rawAccess,
      refreshToken: rawRefresh,
      expiresIn: accessTtl.inSeconds,
      scopes: scopes,
    );
  }

  /// Returns the record for [raw] only if it is an access token, is
  /// unexpired, and is unrevoked; otherwise `null`.
  Future<OAuthToken?> lookupAccess(String raw) =>
      _lookup(raw, OAuthTokenKind.access);

  /// Returns the record for [raw] only if it is a refresh token, is
  /// unexpired, unrevoked, and unrotated; otherwise `null`.
  Future<OAuthToken?> lookupRefresh(String raw) =>
      _lookup(raw, OAuthTokenKind.refresh);

  Future<OAuthToken?> _lookup(String raw, OAuthTokenKind kind) async {
    final record = await _readByRaw(raw);
    if (record == null || record.kind != kind) return null;
    if (record.isRevoked) return null;
    if (kind == OAuthTokenKind.refresh && record.isRotated) return null;
    if (record.isExpired(_clock.nowUtc())) return null;
    return record;
  }

  /// Rotates the refresh token [raw]: marks it rotated and mints a new
  /// pair for the same grant. [scopes], when supplied, SHALL be a subset
  /// of the grant's current scopes (else [ScopeWideningException]).
  ///
  /// Throws [TokenNotFoundException] when [raw] is unknown, not a refresh
  /// token, or expired. Throws [RefreshReuseException] — after revoking
  /// every token of the grant — when [raw] was already rotated or
  /// revoked, since presenting a dead refresh token is a sign of theft.
  Future<IssuedTokens> rotateRefresh(String raw, {Set<String>? scopes}) {
    final hash = hashSecret(raw);
    return _mutex.run(hash, () async {
      final file = _fileFor(hash);
      if (!file.existsSync()) throw const TokenNotFoundException();
      OAuthToken record;
      try {
        record = await _readFile(file);
      } on Exception catch (e) {
        _log.warning('Skipping malformed OAuth token ${file.path}: $e');
        throw const TokenNotFoundException();
      }
      if (record.kind != OAuthTokenKind.refresh) {
        throw const TokenNotFoundException();
      }
      if (record.isRevoked || record.isRotated) {
        final now = _clock.nowUtc();
        await _write(record.revokedCopy(now));
        await _revokeGrant(record.grantId, skipHash: hash);
        throw RefreshReuseException(record.grantId);
      }
      if (record.isExpired(_clock.nowUtc())) {
        throw const TokenNotFoundException();
      }
      final requestedScopes = scopes ?? record.scopes;
      if (!record.scopes.containsAll(requestedScopes)) {
        throw const ScopeWideningException();
      }
      await _write(record.rotatedCopy(_clock.nowUtc()));
      return issue(
        clientId: record.clientId,
        actor: record.actor,
        scopes: requestedScopes,
        resource: record.resource,
        grantId: record.grantId,
      );
    });
  }

  /// Marks every unrevoked record of [grantId] as revoked. Returns the
  /// number of records changed.
  Future<int> revokeGrant(String grantId) => _revokeGrant(grantId);

  Future<int> _revokeGrant(String grantId, {String? skipHash}) async {
    if (!dir.existsSync()) return 0;
    final now = _clock.nowUtc();
    var count = 0;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      OAuthToken record;
      try {
        record = await _readFile(entity);
      } on Exception catch (e) {
        _log.warning('Skipping malformed OAuth token ${entity.path}: $e');
        continue;
      }
      if (record.grantId != grantId || record.isRevoked) continue;
      final revoked = record.revokedCopy(now);
      // The caller already holds the mutex for `skipHash` (it is mid
      // rotation), so re-locking it here would deadlock; write directly.
      if (record.tokenHash == skipHash) {
        await _write(revoked);
      } else {
        await _mutex.run(record.tokenHash, () => _write(revoked));
      }
      count++;
    }
    return count;
  }

  /// Revokes [raw]. An access token is revoked alone; a refresh token
  /// cascades to [revokeGrant] for its whole family. A no-op when [raw]
  /// is unknown.
  ///
  /// When [clientId] is supplied, it SHALL match the token's own
  /// `client_id` or this is a no-op: RFC 7009 §2.1 allows a client to
  /// revoke only tokens it was issued itself.
  Future<void> revokeToken(String raw, {String? clientId}) async {
    final record = await _readByRaw(raw);
    if (record == null) return;
    if (clientId != null && record.clientId != clientId) return;
    if (record.kind == OAuthTokenKind.refresh) {
      await revokeGrant(record.grantId);
      return;
    }
    if (record.isRevoked) return;
    final now = _clock.nowUtc();
    await _mutex.run(record.tokenHash, () => _write(record.revokedCopy(now)));
  }

  /// Deletes every token file whose expiry has passed. Returns the count
  /// removed.
  Future<int> purgeExpired() async {
    if (!dir.existsSync()) return 0;
    final now = _clock.nowUtc();
    var purged = 0;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      OAuthToken record;
      try {
        record = await _readFile(entity);
      } on Exception catch (e) {
        _log.warning('Skipping malformed OAuth token ${entity.path}: $e');
        continue;
      }
      if (record.isExpired(now)) {
        await entity.delete();
        purged++;
      }
    }
    return purged;
  }

  Future<OAuthToken?> _readByRaw(String raw) async {
    final file = _fileFor(hashSecret(raw));
    if (!file.existsSync()) return null;
    try {
      return await _readFile(file);
    } on Exception catch (e) {
      _log.warning('Skipping malformed OAuth token ${file.path}: $e');
      return null;
    }
  }

  File _fileFor(String hash) => File('${dir.path}/$hash.json');

  Future<OAuthToken> _readFile(File file) async {
    final raw = await file.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return OAuthToken.fromJson(json);
  }

  Future<void> _write(OAuthToken record) =>
      atomicWriteJsonFile(_fileFor(record.tokenHash), record.toJson());
}
