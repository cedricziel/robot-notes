import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mime/mime.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/vault_files.dart';

export 'package:server/src/vault_files.dart'
    show FileCollisionException, FileTooLargeException, FileWriteResult;

/// Number of bytes of randomness in a minted upload token. 16 bytes =
/// 128 bits, matching `InviteStore`'s token entropy floor.
const int kUploadTokenBytes = 16;

/// How long a reserved upload slot stays usable if never completed (or
/// never finalized after completing). Short — an upload is expected to
/// finish within minutes, not persist across a server restart (see
/// `add-file-upload`'s design.md Non-Goals).
const Duration kUploadSessionTtl = Duration(minutes: 15);

/// Thrown by [UploadSessionStore.complete] and [UploadSessionStore.finalize]
/// when [token] does not refer to a session usable for that operation —
/// unknown, expired, or in the wrong state (already completed, for
/// [UploadSessionStore.complete]; not yet completed, for
/// [UploadSessionStore.finalize]). Deliberately one exception type for
/// all three cases: callers map it to the same outcome regardless (a
/// `404` on the `PUT` route, a `validation_failed` tool error for
/// `finalize_upload`) since none of them are the caller's to distinguish
/// or retry differently.
class UploadSessionNotFoundException implements Exception {
  /// Creates an exception naming the unusable [token].
  const UploadSessionNotFoundException(this.token);

  /// The token that could not be used.
  final String token;

  @override
  String toString() => 'UploadSessionNotFoundException: $token';
}

enum _Status { pending, uploaded }

class _Session {
  _Session({
    required this.path,
    required this.filename,
    required this.maxBytes,
    required this.expiresAt,
  });

  final String path;
  final String filename;
  final int maxBytes;
  final DateTime expiresAt;
  _Status status = _Status.pending;
  int? size;
  String? contentType;
}

/// In-memory registry of two-phase upload slots: [reserve] mints a
/// single-use token for a `path`/`filename` pair, [complete] streams the
/// raw bytes for that token into a staging file (outside the vault
/// content directory — see `add-file-upload`'s design.md), and
/// [finalize] moves those bytes into the vault via a [FileStore],
/// exactly the write path a direct upload already goes through.
///
/// Session metadata is deliberately not persisted to disk (see
/// design.md's Non-Goals) — a server restart loses any in-flight
/// (never-finalized) session, which is an acceptable trade for not
/// needing atomic-JSON-file machinery for something this short-lived.
/// The staged bytes themselves live at `<stagingDir>/<token>.bin`.
class UploadSessionStore {
  /// Creates a store staging bytes under [stagingDir] (created on first
  /// write). [clock] stamps expiry; [random] supplies token entropy
  /// (tests inject a deterministic source). [ttl] overrides
  /// [kUploadSessionTtl]. A periodic sweep evicts expired sessions and
  /// their staged files every [sweepInterval] — disable by passing
  /// `null` (e.g. in tests that don't want a pending timer).
  UploadSessionStore({
    required this.stagingDir,
    Clock clock = const Clock(),
    Random? random,
    Duration ttl = kUploadSessionTtl,
    Duration? sweepInterval = const Duration(minutes: 5),
  })  : _clock = clock,
        _random = random ?? Random.secure(),
        _ttl = ttl {
    if (sweepInterval != null) {
      _sweepTimer = Timer.periodic(sweepInterval, (_) => _sweepExpired());
    }
  }

  /// Directory staged upload bytes are written to, outside the vault's
  /// `contentDir` so an in-flight upload is never scanned as vault
  /// content.
  final Directory stagingDir;

  final Clock _clock;
  final Random _random;
  final Duration _ttl;
  final Map<String, _Session> _sessions = {};
  Timer? _sweepTimer;

  /// Reserves a single-use upload slot for [path]/[filename], returning
  /// its token and expiry. Does not touch disk or check for a filename
  /// collision — that happens once, at [finalize] time, against
  /// whatever the vault looks like then.
  ({String token, DateTime expiresAt}) reserve({
    required String path,
    required String filename,
    required int maxBytes,
  }) {
    final token = _generateToken();
    final expiresAt = _clock.nowUtc().add(_ttl);
    _sessions[token] = _Session(
      path: path,
      filename: filename,
      maxBytes: maxBytes,
      expiresAt: expiresAt,
    );
    return (token: token, expiresAt: expiresAt);
  }

  /// Streams [bytes] into the staging file for [token], bounded by the
  /// session's reserved `maxBytes`. Throws
  /// [UploadSessionNotFoundException] if [token] is unknown, expired, or
  /// already completed; throws [FileTooLargeException] (deleting any
  /// partial staging file and the session itself) if [bytes] exceeds the
  /// limit.
  Future<({int size, String contentType, DateTime expiresAt})> complete({
    required String token,
    required Stream<List<int>> bytes,
    String? contentType,
  }) async {
    final session = _usable(token, require: _Status.pending);
    if (!stagingDir.existsSync()) {
      await stagingDir.create(recursive: true);
    }
    final file = _stagingFile(token);
    final sink = file.openWrite();
    var total = 0;
    var tooLarge = false;
    try {
      await for (final chunk in bytes) {
        total += chunk.length;
        if (total > session.maxBytes) {
          tooLarge = true;
          break;
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (tooLarge) {
      if (file.existsSync()) await file.delete();
      _sessions.remove(token);
      throw FileTooLargeException(maxBytes: session.maxBytes);
    }
    session
      ..status = _Status.uploaded
      ..size = total
      ..contentType = contentType ??
          lookupMimeType(session.filename) ??
          'application/octet-stream';
    return (
      size: total,
      contentType: session.contentType!,
      expiresAt: session.expiresAt,
    );
  }

  /// Places the completed upload for [token] into the vault via [store]
  /// — the identical sanitization/collision/atomic-write path a direct
  /// upload goes through. The session and its staging file are removed
  /// whether this succeeds or throws (a caller must [reserve] again to
  /// retry after a [FileCollisionException]).
  ///
  /// Throws [UploadSessionNotFoundException] if [token] is unknown,
  /// expired, or has not yet completed via [complete]. Propagates
  /// [FileCollisionException] from [store] untouched.
  Future<FileWriteResult> finalize(String token, FileStore store) async {
    final session = _usable(token, require: _Status.uploaded);
    final file = _stagingFile(token);
    try {
      return await store.write(
        path: session.path,
        filename: session.filename,
        bytes: file.openRead(),
        maxBytes: session.maxBytes,
        contentType: session.contentType,
      );
    } finally {
      _sessions.remove(token);
      if (file.existsSync()) await file.delete();
    }
  }

  _Session _usable(String token, {required _Status require}) {
    final session = _sessions[token];
    if (session == null) throw UploadSessionNotFoundException(token);
    if (!session.expiresAt.isAfter(_clock.nowUtc())) {
      _evict(token);
      throw UploadSessionNotFoundException(token);
    }
    if (session.status != require) {
      throw UploadSessionNotFoundException(token);
    }
    return session;
  }

  void _sweepExpired() {
    final now = _clock.nowUtc();
    final expired = [
      for (final entry in _sessions.entries)
        if (!entry.value.expiresAt.isAfter(now)) entry.key,
    ];
    for (final token in expired) {
      _evict(token);
    }
  }

  void _evict(String token) {
    _sessions.remove(token);
    final file = _stagingFile(token);
    if (file.existsSync()) file.deleteSync();
  }

  File _stagingFile(String token) => File('${stagingDir.path}/$token.bin');

  String _generateToken() {
    final bytes = List<int>.generate(
      kUploadTokenBytes,
      (_) => _random.nextInt(256),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Cancels the periodic expiry sweep. Call once when the owning
  /// the owning AppDeps shuts down.
  void dispose() => _sweepTimer?.cancel();
}
