import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/clock.dart';
import 'package:shared/shared.dart';

/// Number of bytes of randomness in a minted token. 16 bytes = 128 bits
/// — meets the OWASP "session token" entropy floor.
const int kInviteTokenBytes = 16;

/// Default invite TTL when the caller omits one. 24h.
const Duration kDefaultInviteTtl = Duration(hours: 24);

/// Hard ceiling on caller-supplied TTLs. 30 days.
const Duration kMaxInviteTtl = Duration(days: 30);

/// On-disk shape of an invite. Persisted as JSON at
/// `<dataDir>/invites/<token>.json`.
@immutable
class Invite {
  /// Constructs an invite record.
  const Invite({
    required this.token,
    required this.label,
    required this.createdAt,
    required this.expiresAt,
    this.burnedAt,
  });

  /// Parses an invite record from its on-disk JSON form.
  factory Invite.fromJson(Map<String, dynamic> json) => Invite(
        token: json['token'] as String,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
        burnedAt: json['burned_at'] == null
            ? null
            : DateTime.parse(json['burned_at'] as String).toUtc(),
      );

  /// URL-safe token (also the file stem). Treated as the public
  /// identifier — `package:logging` masks it on output.
  final String token;

  /// Free-text label. Used to pick a sensible default `X-Actor`.
  final String label;

  /// First-write time (UTC).
  final DateTime createdAt;

  /// Expiry time (UTC). After this the invite is unusable regardless
  /// of `burnedAt`.
  final DateTime expiresAt;

  /// Time the invite was redeemed. `null` until the bundle is fetched.
  final DateTime? burnedAt;

  /// Whether [now] falls past [expiresAt].
  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  /// Whether [burnedAt] is non-null.
  bool get isBurned => burnedAt != null;

  /// Returns a copy with [burnedAt] applied.
  Invite burnedAtCopy(DateTime when) => Invite(
        token: token,
        label: label,
        createdAt: createdAt,
        expiresAt: expiresAt,
        burnedAt: when,
      );

  /// JSON serialization (matches the on-disk file format).
  Map<String, dynamic> toJson() => {
        'token': token,
        'label': label,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'burned_at': burnedAt?.toUtc().toIso8601String(),
      };

  /// Returns the public-facing summary, suitable for `GET /invites`.
  /// Hides nothing the operator can't see — the API key is delivered
  /// only via the onboarding bundle, never via this DTO.
  InviteSummary toSummary({required DateTime now}) => InviteSummary(
        token: token,
        label: label,
        createdAt: createdAt,
        expiresAt: expiresAt,
        burnedAt: burnedAt,
        expired: isExpired(now),
      );
}

/// Thrown by [InviteStore.burn] when a token has already been redeemed.
@immutable
class AlreadyBurnedException implements Exception {
  /// Describes the conflict. [token] is the offending invite token.
  const AlreadyBurnedException(this.token);

  /// Token that has already been redeemed.
  final String token;

  @override
  String toString() => 'AlreadyBurnedException($token)';
}

/// Thrown by [InviteStore.revoke] when the token does not exist.
@immutable
class InviteNotFoundException implements Exception {
  /// Describes which token was missing.
  const InviteNotFoundException(this.token);

  /// Token that could not be located.
  final String token;

  @override
  String toString() => 'InviteNotFoundException($token)';
}

/// Filesystem-backed store of agent-onboarding invites.
///
/// On-disk layout: each invite lives at `<inviteDir>/<token>.json` and
/// is round-tripped through [Invite]. Mutations use the same
/// tmp+fsync+rename pattern as `Storage` for crash safety; per-token
/// mutexes serialise concurrent burn attempts so exactly one wins.
class InviteStore {
  /// Constructs a store rooted at [inviteDir] (created on first write).
  /// [clock] stamps creation/expiry/burn times. [random] supplies the
  /// entropy for [mint]; tests inject a deterministic source.
  InviteStore({
    required this.inviteDir,
    Clock clock = const Clock(),
    Random? random,
    Logger? logger,
  })  : _clock = clock,
        _random = random ?? Random.secure(),
        _log = logger ?? Logger('invite_store');

  /// Filesystem directory holding `*.json` invite files.
  final Directory inviteDir;

  final Clock _clock;
  final Random _random;
  final Logger _log;
  final Map<String, Future<void>> _locks = {};

  /// Mints a new invite with [label] and [ttl] (clamped to
  /// [kMaxInviteTtl]; defaults to [kDefaultInviteTtl]). Persists it
  /// atomically and returns the freshly minted record.
  Future<Invite> mint({required String label, Duration? ttl}) async {
    final now = _clock.nowUtc();
    final effectiveTtl = ttl ?? kDefaultInviteTtl;
    if (effectiveTtl <= Duration.zero) {
      throw ArgumentError('ttl must be positive');
    }
    if (effectiveTtl > kMaxInviteTtl) {
      throw ArgumentError('ttl exceeds $kMaxInviteTtl');
    }
    final token = _generateToken();
    final invite = Invite(
      token: token,
      label: label,
      createdAt: now,
      expiresAt: now.add(effectiveTtl),
    );
    await _withLock(token, () => _atomicWrite(invite));
    return invite;
  }

  /// Lists every well-formed invite, computing `expired` against the
  /// current clock. Files that fail to parse are logged and skipped.
  Future<List<InviteSummary>> list() async {
    if (!inviteDir.existsSync()) return const [];
    final now = _clock.nowUtc();
    final entries = <InviteSummary>[];
    await for (final entity in inviteDir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      try {
        final invite = await _readFile(entity);
        entries.add(invite.toSummary(now: now));
      } on Exception catch (e) {
        _log.warning('Skipping malformed invite ${entity.path}: $e');
      }
    }
    entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return entries;
  }

  /// Returns the invite for [token] or `null` if no such file exists.
  Future<Invite?> get(String token) async {
    final file = _fileFor(token);
    if (!file.existsSync()) return null;
    try {
      return await _readFile(file);
    } on Exception catch (e) {
      _log.warning('Skipping malformed invite ${file.path}: $e');
      return null;
    }
  }

  /// Atomically marks [token] as burned. Returns the *previous*
  /// (unburned) state so the caller can render the bundle exactly once.
  /// Throws [AlreadyBurnedException] if the invite has already been
  /// redeemed, or [InviteNotFoundException] if it does not exist.
  Future<Invite> burn(String token) {
    return _withLock(token, () async {
      final file = _fileFor(token);
      if (!file.existsSync()) throw InviteNotFoundException(token);
      final invite = await _readFile(file);
      if (invite.isBurned) throw AlreadyBurnedException(token);
      final now = _clock.nowUtc();
      await _atomicWrite(invite.burnedAtCopy(now));
      return invite;
    });
  }

  /// Deletes the invite file for [token]. Throws
  /// [InviteNotFoundException] if it does not exist.
  Future<void> revoke(String token) {
    return _withLock(token, () async {
      final file = _fileFor(token);
      if (!file.existsSync()) throw InviteNotFoundException(token);
      await file.delete();
    });
  }

  String _generateToken() {
    final bytes = List<int>.generate(
      kInviteTokenBytes,
      (_) => _random.nextInt(256),
    );
    // base64url-without-padding ≈ 22 chars, URL-safe.
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  File _fileFor(String token) => File('${inviteDir.path}/$token.json');

  Future<Invite> _readFile(File file) async {
    final raw = await file.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return Invite.fromJson(json);
  }

  Future<void> _atomicWrite(Invite invite) async {
    if (!inviteDir.existsSync()) {
      await inviteDir.create(recursive: true);
    }
    final encoded = jsonEncode(invite.toJson());
    final finalFile = _fileFor(invite.token);
    final tmp = File('${finalFile.path}.tmp');
    final raf = await tmp.open(mode: FileMode.writeOnly);
    try {
      await raf.writeString(encoded);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(finalFile.path);
  }

  /// Per-token mutex. Identical pattern to `Storage._withLock` —
  /// serialises mutations on the same token so [burn] is exclusive.
  Future<T> _withLock<T>(String token, Future<T> Function() body) {
    final completer = Completer<T>();
    final previous = _locks[token] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await body());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _locks[token] = next.then((_) {
      // Drop stale entries to keep the map bounded.
      if (identical(_locks[token], next)) _locks.remove(token);
    });
    return completer.future;
  }
}
