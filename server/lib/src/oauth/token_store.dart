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

/// Thrown by [TokenStore.issue] when [grantId] already has a revoked
/// record on disk. Grant revocation is terminal: once any token of a
/// grant has been revoked, no further token may be minted for it, even
/// if the mint raced the revocation.
@immutable
class GrantRevokedException implements Exception {
  /// Creates the exception for the grant that was already revoked.
  const GrantRevokedException(this.grantId);

  /// Grant id that was already revoked.
  final String grantId;

  @override
  String toString() => 'GrantRevokedException($grantId)';
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

  /// Raw credential for the next `/oauth/token` refresh, or `null` when
  /// [TokenStore.issue] was called with `withRefresh: false`.
  final String? refreshToken;

  /// Access-token lifetime in seconds, for the token-response `expires_in`
  /// field.
  final int expiresIn;

  /// Scopes granted to both tokens.
  final Set<String> scopes;
}

/// Filesystem-backed store of hashed OAuth access and refresh tokens.
///
/// On-disk layout: each token lives at `<dir>/<sha256(token)>.json`,
/// following the same tmp+fsync+rename pattern as `InviteStore`. Only the
/// SHA-256 hash of the raw token is ever written. Every token minted from
/// one consent shares a `grant_id`, so [revokeGrant] can cascade with a
/// single directory scan.
///
/// [issue], [rotateRefresh], and [revokeGrant] all serialize on a
/// `grant:<grantId>` key of the same [KeyedMutex], rather than on
/// individual token hashes: a grant's tokens must be mutated as one unit,
/// since [revokeGrant]'s directory scan and [rotateRefresh]'s mint of a
/// replacement pair both need a consistent view of "every token of this
/// grant," not just of the one token hash each happens to know about.
class TokenStore {
  /// Constructs a store rooted at [dir] (created on first write). [clock]
  /// stamps issue/revoke/rotate time. [random] supplies the entropy for
  /// minted tokens; tests inject a deterministic source. [onGrantRevoked],
  /// when supplied, runs after every successful [revokeGrant] (explicit or
  /// reuse-triggered) with the revoked grant id, so a caller can cascade
  /// the revocation to other stores that share the same `grant_id` (e.g.
  /// revoking outstanding authorization codes).
  TokenStore({
    required this.dir,
    Clock clock = const Clock(),
    Random? random,
    Logger? logger,
    Future<void> Function(String grantId)? onGrantRevoked,
  })  : _clock = clock,
        _random = random ?? Random.secure(),
        _log = logger ?? Logger('oauth.token_store'),
        _onGrantRevoked = onGrantRevoked;

  /// Access tokens are valid for 1 hour from issue.
  static const accessTtl = Duration(hours: 1);

  /// Refresh tokens are valid for 30 days from issue.
  static const refreshTtl = Duration(days: 30);

  /// Filesystem directory holding `*.json` token files.
  final Directory dir;

  final Clock _clock;
  final Random _random;
  final Logger _log;
  final Future<void> Function(String grantId)? _onGrantRevoked;
  final _mutex = KeyedMutex();

  /// Mints a fresh access token for [grantId], persisted as a hashed
  /// record; also mints and persists a paired refresh token unless
  /// [withRefresh] is `false`, in which case [IssuedTokens.refreshToken]
  /// is `null` and no refresh file is ever written — for clients not
  /// registered for the `refresh_token` grant, which have no way to use
  /// one.
  ///
  /// Runs under the grant's lock (see the class doc), so it can never
  /// interleave with a concurrent [rotateRefresh] or [revokeGrant] for the
  /// same [grantId].
  Future<IssuedTokens> issue({
    required String clientId,
    required String actor,
    required Set<String> scopes,
    required String resource,
    required String grantId,
    bool withRefresh = true,
  }) =>
      _mutex.run(
        _grantKey(grantId),
        () => _issueLocked(
          clientId: clientId,
          actor: actor,
          scopes: scopes,
          resource: resource,
          grantId: grantId,
          withRefresh: withRefresh,
        ),
      );

  Future<IssuedTokens> _issueLocked({
    required String clientId,
    required String actor,
    required Set<String> scopes,
    required String resource,
    required String grantId,
    bool withRefresh = true,
  }) async {
    // Grant revocation is terminal: a grant that already has a revoked
    // record on disk must never gain a fresh, live token, even if this
    // mint raced the revocation and won the race for the grant lock
    // before the revocation was requested.
    if (await _grantHasRevokedRecord(grantId)) {
      throw GrantRevokedException(grantId);
    }
    final now = _clock.nowUtc();
    final rawAccess = generateRandomToken(_random, kOAuthTokenBytes);
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
    await _write(access);
    String? rawRefresh;
    if (withRefresh) {
      rawRefresh = generateRandomToken(_random, kOAuthTokenBytes);
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
      await _write(refresh);
    }
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
  /// unexpired, unrevoked, and unrotated; otherwise `null`. Accepts a
  /// `null` [raw] (returning `null`) since [IssuedTokens.refreshToken] is
  /// itself nullable.
  Future<OAuthToken?> lookupRefresh(String? raw) =>
      raw == null ? Future.value() : _lookup(raw, OAuthTokenKind.refresh);

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
  /// Throws [TokenNotFoundException] when [raw] is `null`, unknown, not a
  /// refresh token, or expired. Throws [RefreshReuseException] — after
  /// revoking every token of the grant — when [raw] was already rotated
  /// or revoked, since presenting a dead refresh token is a sign of theft.
  Future<IssuedTokens> rotateRefresh(
    String? raw, {
    Set<String>? scopes,
  }) async {
    if (raw == null) throw const TokenNotFoundException();
    final hash = hashSecret(raw);
    final file = _fileFor(hash);
    // Peeked without holding any lock, purely to learn which grant to
    // lock: `grantId` never changes once a record is written (no copy
    // method touches it), so this can't observe a torn value — at worst
    // the record vanishes or changes underneath us before the locked
    // re-read below, which that re-read handles.
    final peekedGrantId = await _peekGrantId(file);
    if (peekedGrantId == null) throw const TokenNotFoundException();
    // Set only on the reuse path, and read after the mutex below has
    // released the grant lock: `_onGrantRevoked` can cross into another
    // store (e.g. CodeStore.revokeGrant) that takes its own per-record
    // lock, and calling it while still holding this grant's lock risks a
    // lock-ordering deadlock against a caller that holds that other lock
    // first and is waiting on this one (e.g. a code-exchange callback
    // that itself calls TokenStore.issue for the same grant).
    String? reusedGrantId;
    try {
      return await _mutex.run(_grantKey(peekedGrantId), () async {
        if (!file.existsSync()) throw const TokenNotFoundException();
        OAuthToken record;
        try {
          record = await _readFile(file);
        } on Object catch (e) {
          _log.warning('Skipping malformed OAuth token ${file.path}: $e');
          throw const TokenNotFoundException();
        }
        if (record.kind != OAuthTokenKind.refresh) {
          throw const TokenNotFoundException();
        }
        if (record.isRevoked || record.isRotated) {
          final now = _clock.nowUtc();
          await _write(record.revokedCopy(now));
          // Already holding this grant's lock, so revoke directly instead
          // of calling the public revokeGrant (which would re-acquire it
          // and deadlock).
          await _revokeGrantLocked(record.grantId);
          reusedGrantId = record.grantId;
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
        return _issueLocked(
          clientId: record.clientId,
          actor: record.actor,
          scopes: requestedScopes,
          resource: record.resource,
          grantId: record.grantId,
        );
      });
    } finally {
      if (reusedGrantId != null) {
        await _onGrantRevoked?.call(reusedGrantId!);
      }
    }
  }

  /// Marks every unrevoked record of [grantId] as revoked, then runs the
  /// `onGrantRevoked` callback (if supplied) with [grantId]. Returns the
  /// number of records changed.
  ///
  /// Runs under the grant's lock, so a concurrent [issue] or
  /// [rotateRefresh] for the same [grantId] can never mint a token this
  /// scan misses: either it completes before this starts (and gets
  /// caught by the scan), or it waits for this to finish first.
  Future<int> revokeGrant(String grantId) async {
    final count = await _mutex.run(
      _grantKey(grantId),
      () => _revokeGrantLocked(grantId),
    );
    await _onGrantRevoked?.call(grantId);
    return count;
  }

  Future<int> _revokeGrantLocked(String grantId) async {
    if (!dir.existsSync()) return 0;
    final now = _clock.nowUtc();
    var count = 0;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      OAuthToken record;
      try {
        record = await _readFile(entity);
      } on Object catch (e) {
        _log.warning('Skipping malformed OAuth token ${entity.path}: $e');
        continue;
      }
      if (record.grantId != grantId || record.isRevoked) continue;
      await _write(record.revokedCopy(now));
      count++;
    }
    return count;
  }

  /// Whether any persisted record of [grantId] is already revoked. Called
  /// under the grant's lock, so it sees every record a concurrent
  /// [revokeGrant] for the same grant has written by the time either
  /// operation acquires the lock.
  Future<bool> _grantHasRevokedRecord(String grantId) async {
    if (!dir.existsSync()) return false;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      OAuthToken record;
      try {
        record = await _readFile(entity);
      } on Object catch (e) {
        _log.warning('Skipping malformed OAuth token ${entity.path}: $e');
        continue;
      }
      if (record.grantId == grantId && record.isRevoked) return true;
    }
    return false;
  }

  /// Revokes [raw]. An access token is revoked alone; a refresh token
  /// cascades to [revokeGrant] for its whole family. A no-op when [raw]
  /// is `null` or unknown.
  ///
  /// When [clientId] is supplied, it SHALL match the token's own
  /// `client_id` or this is a no-op: RFC 7009 §2.1 allows a client to
  /// revoke only tokens it was issued itself.
  Future<void> revokeToken(String? raw, {String? clientId}) async {
    if (raw == null) return;
    final peeked = await _readByRaw(raw);
    if (peeked == null) return;
    if (clientId != null && peeked.clientId != clientId) return;
    if (peeked.kind == OAuthTokenKind.refresh) {
      await revokeGrant(peeked.grantId);
      return;
    }
    await _mutex.run(_grantKey(peeked.grantId), () async {
      // Re-read under the grant's lock: `peeked` may be stale if a
      // concurrent revokeGrant or rotateRefresh already touched it.
      final record = await _readByRaw(raw);
      if (record == null || record.kind != OAuthTokenKind.access) return;
      if (clientId != null && record.clientId != clientId) return;
      if (record.isRevoked) return;
      await _write(record.revokedCopy(_clock.nowUtc()));
    });
  }

  Future<String?> _peekGrantId(File file) async {
    if (!file.existsSync()) return null;
    try {
      return (await _readFile(file)).grantId;
    } on Object catch (e) {
      _log.warning('Skipping malformed OAuth token ${file.path}: $e');
      return null;
    }
  }

  String _grantKey(String grantId) => 'grant:$grantId';

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
      } on Object catch (e) {
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
    } on Object catch (e) {
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
