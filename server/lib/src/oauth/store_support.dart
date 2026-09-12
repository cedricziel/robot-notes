import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Serializes async operations keyed by an arbitrary string: concurrent
/// callers touching the same key run one at a time, callers touching
/// different keys run freely. `ClientStore`, `CodeStore`, and
/// `TokenStore` each hold one instance to guard their own file set,
/// mirroring the mutex `InviteStore` inlines for its single file set.
class KeyedMutex {
  final Map<String, Future<void>> _pending = {};

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
    _pending[key] = next.then((_) {
      // Drop stale entries to keep the map bounded.
      if (identical(_pending[key], next)) _pending.remove(key);
    });
    return completer.future;
  }
}

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
