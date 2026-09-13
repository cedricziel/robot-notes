import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/upload_sessions.dart';
import 'package:server/src/vault_files.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-upload-sessions-test-');

void main() {
  late Directory tmp;
  late Directory stagingDir;
  late Directory contentDir;
  late FileStore fileStore;

  setUp(() {
    tmp = _tempDir();
    stagingDir = Directory('${tmp.path}/uploads');
    contentDir = Directory('${tmp.path}/content');
    fileStore = FileStore(contentDir: contentDir);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('reserve', () {
    test('returns a token and a future expiry', () {
      final store = UploadSessionStore(
        stagingDir: stagingDir,
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
        sweepInterval: null,
      );

      final reserved = store.reserve(
        path: 'Ideas',
        filename: 'photo.png',
        maxBytes: 1024,
      );

      expect(reserved.token, isNotEmpty);
      expect(reserved.expiresAt.isAfter(DateTime.utc(2026, 4, 25, 10)), isTrue);
      store.dispose();
    });
  });

  group('complete', () {
    test('streams bytes to a staging file and marks the session uploaded',
        () async {
      final store =
          UploadSessionStore(stagingDir: stagingDir, sweepInterval: null);
      final reserved = store.reserve(
        path: 'Ideas',
        filename: 'photo.png',
        maxBytes: 1024,
      );

      final result = await store.complete(
        token: reserved.token,
        bytes: Stream.value([1, 2, 3]),
        contentType: 'image/png',
      );

      expect(result.size, 3);
      expect(result.contentType, 'image/png');
      expect(
        File('${stagingDir.path}/${reserved.token}.bin').existsSync(),
        isTrue,
      );
      store.dispose();
    });

    test('completing an unknown token throws', () async {
      final store =
          UploadSessionStore(stagingDir: stagingDir, sweepInterval: null);

      await expectLater(
        store.complete(token: 'nope', bytes: Stream.value([1])),
        throwsA(isA<UploadSessionNotFoundException>()),
      );
      store.dispose();
    });

    test('completing an already-uploaded token throws', () async {
      final store =
          UploadSessionStore(stagingDir: stagingDir, sweepInterval: null);
      final reserved = store.reserve(
        path: 'Ideas',
        filename: 'photo.png',
        maxBytes: 1024,
      );
      await store.complete(token: reserved.token, bytes: Stream.value([1]));

      await expectLater(
        store.complete(token: reserved.token, bytes: Stream.value([2])),
        throwsA(isA<UploadSessionNotFoundException>()),
      );
      store.dispose();
    });

    test(
        'exceeding maxBytes deletes the partial staging file and the '
        'session', () async {
      final store =
          UploadSessionStore(stagingDir: stagingDir, sweepInterval: null);
      final reserved = store.reserve(
        path: 'Ideas',
        filename: 'big.bin',
        maxBytes: 5,
      );

      await expectLater(
        store.complete(
          token: reserved.token,
          bytes: Stream.fromIterable([
            List.filled(3, 65),
            List.filled(3, 66),
          ]),
        ),
        throwsA(isA<FileTooLargeException>()),
      );
      expect(
        File('${stagingDir.path}/${reserved.token}.bin').existsSync(),
        isFalse,
      );
      await expectLater(
        store.complete(token: reserved.token, bytes: Stream.value([1])),
        throwsA(isA<UploadSessionNotFoundException>()),
      );
      store.dispose();
    });

    test('an expired session behaves as not-found', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 11),
      ]);
      final store = UploadSessionStore(
        stagingDir: stagingDir,
        clock: clock,
        sweepInterval: null,
      );
      final reserved = store.reserve(
        path: 'Ideas',
        filename: 'photo.png',
        maxBytes: 1024,
      );

      await expectLater(
        store.complete(token: reserved.token, bytes: Stream.value([1])),
        throwsA(isA<UploadSessionNotFoundException>()),
      );
      store.dispose();
    });
  });

  group('finalize', () {
    test('places completed bytes into the vault via FileStore', () async {
      final store =
          UploadSessionStore(stagingDir: stagingDir, sweepInterval: null);
      final reserved = store.reserve(
        path: 'Ideas',
        filename: 'photo.png',
        maxBytes: 1024,
      );
      await store.complete(
        token: reserved.token,
        bytes: Stream.value([1, 2, 3]),
        contentType: 'image/png',
      );

      final result = await store.finalize(reserved.token, fileStore);

      expect(result.path, 'Ideas');
      expect(result.filename, 'photo.png');
      expect(result.size, 3);
      expect(
        File('${contentDir.path}/Ideas/photo.png').existsSync(),
        isTrue,
      );
      expect(
        File('${stagingDir.path}/${reserved.token}.bin').existsSync(),
        isFalse,
      );
      store.dispose();
    });

    test('finalizing before complete throws', () async {
      final store =
          UploadSessionStore(stagingDir: stagingDir, sweepInterval: null);
      final reserved = store.reserve(
        path: 'Ideas',
        filename: 'photo.png',
        maxBytes: 1024,
      );

      await expectLater(
        store.finalize(reserved.token, fileStore),
        throwsA(isA<UploadSessionNotFoundException>()),
      );
      store.dispose();
    });

    test('finalizing an unknown token throws', () async {
      final store =
          UploadSessionStore(stagingDir: stagingDir, sweepInterval: null);

      await expectLater(
        store.finalize('nope', fileStore),
        throwsA(isA<UploadSessionNotFoundException>()),
      );
      store.dispose();
    });

    test(
        'a collision at finalize time propagates and cleans up the '
        'session', () async {
      await fileStore.write(
        path: 'Ideas',
        filename: 'photo.png',
        bytes: Stream.value([9]),
        maxBytes: 1024,
      );
      final store =
          UploadSessionStore(stagingDir: stagingDir, sweepInterval: null);
      final reserved = store.reserve(
        path: 'Ideas',
        filename: 'photo.png',
        maxBytes: 1024,
      );
      await store.complete(token: reserved.token, bytes: Stream.value([1]));

      await expectLater(
        store.finalize(reserved.token, fileStore),
        throwsA(isA<FileCollisionException>()),
      );
      expect(
        File('${stagingDir.path}/${reserved.token}.bin').existsSync(),
        isFalse,
      );
      await expectLater(
        store.finalize(reserved.token, fileStore),
        throwsA(isA<UploadSessionNotFoundException>()),
      );
      // The pre-existing file is unchanged.
      expect(
        File('${contentDir.path}/Ideas/photo.png').readAsBytesSync(),
        [9],
      );
      store.dispose();
    });
  });
}
