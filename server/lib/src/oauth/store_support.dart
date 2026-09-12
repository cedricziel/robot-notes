import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// Serializes async operations keyed by an arbitrary string: concurrent
/// callers touching the same key run one at a time, callers touching
/// different keys run freely. `ClientStore`, `CodeStore`, and
/// `TokenStore` each hold one instance to guard their own file set, and
/// `InviteStore` shares this implementation for its single file set.
class KeyedMutex {
  final Map<String, Future<void>> _pending = {};

  /// Number of keys with an in-flight or queued operation. Exposed for
  /// tests to confirm the map does not grow unboundedly.
  @visibleForTesting
  int get pendingCount => _pending.length;

  /// Runs [body] exclusively for [key], waiting for any in-flight
  /// operation on the same key to finish first.
  Future<T> run<T>(String key, Future<T> Function() body) {
    final completer = Completer<T>();
    final previous = _pending[key] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await body());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    // `finalizer` is referenced by its own callback below, so it must be
    // assigned before the callback can run; `late` makes that legal even
    // though the assignment happens after the reference appears in source.
    late final Future<void> finalizer;
    finalizer = next.then((_) {
      // Only remove the entry if nothing chained onto this key since —
      // comparing against `finalizer` itself (not `next`) is what makes
      // this check correct, since `finalizer` is what got stored below.
      if (identical(_pending[key], finalizer)) _pending.remove(key);
    });
    _pending[key] = finalizer;
    return completer.future;
  }
}

/// Matches a value safe to interpolate into a filesystem path as
/// `<dir>/<value>.json`. Minted ids (client ids, invite tokens) and
/// sha256 hex digests (code/token file stems) always match this pattern;
/// anything else — in particular `..` or `/` — is rejected before it
/// reaches the filesystem, closing off path traversal and absolute-path
/// injection for keys that come straight from a request.
final RegExp _kSafeStoreKey = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Returns whether [key] is safe to use as a store file stem: a non-empty
/// run of URL-safe token characters, up to 64 of them, with no `.`, `/`,
/// or other path-traversal metacharacters.
bool isSafeStoreKey(String key) => _kSafeStoreKey.hasMatch(key);

/// Writes [json] to [file] via tmp+fsync+rename, matching the crash-safe
/// pattern `Storage` and `InviteStore` use for every on-disk record.
/// Creates the parent directory on first write.
Future<void> atomicWriteJsonFile(File file, Map<String, dynamic> json) async {
  final dir = file.parent;
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  final encoded = jsonEncode(json);
  final tmp = File('${file.path}.tmp');
  final raf = await tmp.open(mode: FileMode.writeOnly);
  try {
    await raf.writeString(encoded);
    await raf.flush();
  } finally {
    await raf.close();
  }
  await tmp.rename(file.path);
}
