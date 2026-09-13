import 'dart:async';
import 'dart:io';

import 'package:server/src/vault_files.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-vault-files-test-');

Stream<List<int>> _bytesOf(String s) => Stream.value(s.codeUnits);

void main() {
  late Directory tmp;
  late FileStore store;

  setUp(() {
    tmp = _tempDir();
    store = FileStore(contentDir: Directory('${tmp.path}/content'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('FileStore.write', () {
    test('sanitizes path and filename the same way notes do', () async {
      final result = await store.write(
        path: 'Projects/Alpha',
        filename: 'My File.PNG',
        bytes: _bytesOf('hi'),
        maxBytes: 1024,
      );

      expect(result.path, 'Projects/Alpha');
      expect(result.filename, 'My File.PNG');
      expect(
        File('${tmp.path}/content/Projects/Alpha/My File.PNG').existsSync(),
        isTrue,
      );
    });

    test('rejects an invalid path segment', () {
      expect(
        () => store.write(
          path: 'Projects/../etc',
          filename: 'a.txt',
          bytes: _bytesOf('hi'),
          maxBytes: 1024,
        ),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test('writes to the vault root when path is empty', () async {
      final result = await store.write(
        path: '',
        filename: 'root.txt',
        bytes: _bytesOf('hi'),
        maxBytes: 1024,
      );

      expect(result.path, '');
      expect(File('${tmp.path}/content/root.txt').existsSync(), isTrue);
    });

    test(
        'a filename collision (case/NFC-insensitive) throws without '
        'writing', () async {
      await store.write(
        path: 'Ideas',
        filename: 'diagram.png',
        bytes: _bytesOf('one'),
        maxBytes: 1024,
      );

      await expectLater(
        store.write(
          path: 'Ideas',
          filename: 'Diagram.PNG',
          bytes: _bytesOf('two'),
          maxBytes: 1024,
        ),
        throwsA(isA<FileCollisionException>()),
      );
      expect(
        File('${tmp.path}/content/Ideas/diagram.png').readAsStringSync(),
        'one',
      );
    });

    test('a target with no collision writes cleanly with the right size',
        () async {
      final result = await store.write(
        path: 'Ideas',
        filename: 'note.txt',
        bytes: _bytesOf('hello'),
        maxBytes: 1024,
      );

      expect(result.size, 5);
      expect(result.contentType, 'text/plain');
    });

    test(
        'aborts and leaves no partial file when the stream exceeds '
        'maxBytes', () async {
      final chunks = Stream<List<int>>.fromIterable([
        List.filled(10, 65),
        List.filled(10, 66),
      ]);

      await expectLater(
        store.write(
          path: 'Ideas',
          filename: 'big.bin',
          bytes: chunks,
          maxBytes: 15,
        ),
        throwsA(isA<FileTooLargeException>()),
      );
      expect(
        Directory('${tmp.path}/content/Ideas').listSync().whereType<File>(),
        isEmpty,
      );
    });

    test(
        'two concurrent writes to the same new target: exactly one '
        'succeeds', () async {
      final results = await Future.wait<Object>([
        store
            .write(
              path: 'Ideas',
              filename: 'race.txt',
              bytes: _bytesOf('a'),
              maxBytes: 1024,
            )
            .then<Object>((r) => r)
            .catchError((Object e) => e),
        store
            .write(
              path: 'Ideas',
              filename: 'race.txt',
              bytes: _bytesOf('b'),
              maxBytes: 1024,
            )
            .then<Object>((r) => r)
            .catchError((Object e) => e),
      ]);

      final succeeded = results.whereType<FileWriteResult>().toList();
      final failed = results.whereType<FileCollisionException>().toList();
      expect(succeeded, hasLength(1));
      expect(failed, hasLength(1));
    });
  });
}
