import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/vault_files.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/files/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required Storage storage,
  required FileStore fileStore,
  Config? config,
  Uri? uri,
  FormData? formData,
  Object formDataError = _noError,
  Map<String, String> headers = const {},
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri)
      .thenReturn(uri ?? Uri.parse('http://localhost/notes/files'));
  when(() => req.headers).thenReturn(headers);
  if (!identical(formDataError, _noError)) {
    when(req.formData).thenThrow(formDataError);
  } else {
    when(req.formData).thenAnswer((_) async => formData!);
  }
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Storage>()).thenReturn(storage);
  when(() => ctx.read<FileStore>()).thenReturn(fileStore);
  when(() => ctx.read<Config>()).thenReturn(
    config ??
        const Config(apiKey: 'k', dataDir: '/tmp', port: 0, lockTtlSeconds: 60),
  );
  when(() => ctx.read<Clock>()).thenReturn(const Clock());
  return ctx;
}

const Object _noError = Object();

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-files-index-test-');

void main() {
  late Directory tmp;
  late Storage storage;
  late FileStore fileStore;

  setUp(() {
    tmp = _tempDir();
    storage = Storage(contentDir: Directory('${tmp.path}/content'));
    fileStore = FileStore(contentDir: Directory('${tmp.path}/content'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('POST /notes/files', () {
    test('uploads a file to the vault root', () async {
      final formData = FormData(
        fields: {'path': ''},
        files: {
          'file': UploadedFile(
            'diagram.png',
            ContentType('image', 'png'),
            Stream.value([1, 2, 3]),
          ),
        },
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          fileStore: fileStore,
          formData: formData,
        ),
      );

      expect(res.statusCode, HttpStatus.created);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {
        'path': '',
        'filename': 'diagram.png',
        'size': 3,
        'content_type': 'image/png',
      });
      expect(
        File('${tmp.path}/content/diagram.png').existsSync(),
        isTrue,
      );
    });

    test('registers the upload so it is immediately listable', () async {
      final formData = FormData(
        fields: {'path': 'Ideas'},
        files: {
          'file': UploadedFile(
            'diagram.png',
            ContentType('image', 'png'),
            Stream.value([1, 2, 3]),
          ),
        },
      );

      await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          fileStore: fileStore,
          formData: formData,
        ),
      );

      expect(
        storage.filesIn('Ideas').map((f) => f.relativePath),
        ['Ideas/diagram.png'],
      );
    });

    test('a filename collision returns 409', () async {
      await fileStore.write(
        path: 'Ideas',
        filename: 'diagram.png',
        bytes: Stream.value([1]),
        maxBytes: 1024,
      );
      final formData = FormData(
        fields: {'path': 'Ideas'},
        files: {
          'file': UploadedFile(
            'diagram.png',
            ContentType('image', 'png'),
            Stream.value([1, 2, 3]),
          ),
        },
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          fileStore: fileStore,
          formData: formData,
        ),
      );

      expect(res.statusCode, HttpStatus.conflict);
    });

    test('an oversized upload returns 413', () async {
      final formData = FormData(
        fields: {'path': ''},
        files: {
          'file': UploadedFile(
            'big.bin',
            ContentType('application', 'octet-stream'),
            Stream.value(List.filled(30, 1)),
          ),
        },
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          fileStore: fileStore,
          formData: formData,
          config: const Config(
            apiKey: 'k',
            dataDir: '/tmp',
            port: 0,
            lockTtlSeconds: 60,
            maxUploadSizeBytes: 10,
          ),
        ),
      );

      expect(res.statusCode, HttpStatus.requestEntityTooLarge);
    });

    test('an invalid path segment returns 400', () async {
      final formData = FormData(
        fields: {'path': '../etc'},
        files: {
          'file': UploadedFile(
            'a.txt',
            ContentType('text', 'plain'),
            Stream.value([1]),
          ),
        },
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          fileStore: fileStore,
          formData: formData,
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('a missing path field returns 400', () async {
      final formData = FormData(
        fields: {},
        files: {
          'file': UploadedFile(
            'a.txt',
            ContentType('text', 'plain'),
            Stream.value([1]),
          ),
        },
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          fileStore: fileStore,
          formData: formData,
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('a missing file field returns 400', () async {
      const formData = FormData(fields: {'path': ''}, files: {});

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          fileStore: fileStore,
          formData: formData,
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('a non-multipart body returns 400', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          storage: storage,
          fileStore: fileStore,
          formDataError: StateError('not multipart'),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });
  });

  group('GET /notes/files', () {
    test("lists a folder's direct files, excluding subfolders", () async {
      await fileStore.write(
        path: 'Ideas',
        filename: 'diagram.png',
        bytes: Stream.value([1, 2]),
        maxBytes: 1024,
      );
      await fileStore.write(
        path: 'Ideas',
        filename: 'notes.pdf',
        bytes: Stream.value([1, 2, 3]),
        maxBytes: 1024,
      );
      await fileStore.write(
        path: 'Ideas/Sub',
        filename: 'other.png',
        bytes: Stream.value([1]),
        maxBytes: 1024,
      );
      await storage.list();

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          storage: storage,
          fileStore: fileStore,
          uri: Uri.parse('http://localhost/notes/files?path=Ideas'),
        ),
      );

      final body = await res.json() as Map<String, dynamic>;
      final items = (body['items'] as List).cast<Map<String, dynamic>>();
      expect(
        items.map((i) => i['filename']).toList()..sort(),
        ['diagram.png', 'notes.pdf'],
      );
      expect(items.every((i) => i['path'] == 'Ideas'), isTrue);
    });

    test('an omitted path lists the vault root', () async {
      await fileStore.write(
        path: '',
        filename: 'root.txt',
        bytes: Stream.value([1]),
        maxBytes: 1024,
      );
      await storage.list();

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, storage: storage, fileStore: fileStore),
      );

      final body = await res.json() as Map<String, dynamic>;
      final items = (body['items'] as List).cast<Map<String, dynamic>>();
      expect(items.map((i) => i['filename']), ['root.txt']);
    });
  });

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.delete, storage: storage, fileStore: fileStore),
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });
}
