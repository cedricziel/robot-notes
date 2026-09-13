import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/attachments.dart';
import 'package:server/src/config.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/attachments/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required AttachmentStore attachmentStore,
  int maxUploadSizeBytes = 26214400,
  FormData? formData,
  Object? formDataError,
  Map<String, String> headers = const {},
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.headers).thenReturn(headers);
  if (formDataError != null) {
    when(req.formData).thenThrow(formDataError);
  } else if (formData != null) {
    when(req.formData).thenAnswer((_) async => formData);
  }
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<AttachmentStore>()).thenReturn(attachmentStore);
  when(() => ctx.read<Config>()).thenReturn(
    Config(
      apiKey: 'test',
      dataDir: '/tmp/unused',
      port: 0,
      lockTtlSeconds: 60,
      maxUploadSizeBytes: maxUploadSizeBytes,
    ),
  );
  return ctx;
}

FormData _formData({
  required Map<String, String> fields,
  String? fileFieldName = 'file',
  String filename = 'note.txt',
  String content = 'hello',
  String contentType = 'text/plain',
}) {
  return FormData(
    fields: fields,
    files: fileFieldName == null
        ? {}
        : {
            fileFieldName: UploadedFile(
              filename,
              ContentType.parse(contentType),
              Stream.value(content.codeUnits),
            ),
          },
  );
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-attachments-route-test-');

void main() {
  late Directory tmp;
  late AttachmentStore store;

  setUp(() {
    tmp = _tempDir();
    store = AttachmentStore(contentDir: Directory('${tmp.path}/content'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, attachmentStore: store),
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });

  group('POST /notes/attachments', () {
    test('uploads a file to the vault root and returns 201', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          formData: _formData(fields: {'path': ''}),
        ),
      );

      expect(res.statusCode, HttpStatus.created);
      final body = await res.json() as Map<String, dynamic>;
      expect(body, {
        'path': '',
        'filename': 'note.txt',
        'size': 5,
        'content_type': 'text/plain',
      });
      expect(File('${tmp.path}/content/note.txt').existsSync(), isTrue);
    });

    test('creates missing intermediate folders for a nested path', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          formData: _formData(fields: {'path': 'Projects/Alpha'}),
        ),
      );

      expect(res.statusCode, HttpStatus.created);
      expect(
        File('${tmp.path}/content/Projects/Alpha/note.txt').existsSync(),
        isTrue,
      );
    });

    test(
        'a filename collision returns 409 and does not modify the '
        'existing file', () async {
      await store.write(
        path: 'Ideas',
        filename: 'note.txt',
        bytes: Stream.value('original'.codeUnits),
        maxBytes: 1024,
      );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          formData: _formData(fields: {'path': 'Ideas'}),
        ),
      );

      expect(res.statusCode, HttpStatus.conflict);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'path_conflict');
      expect(
        File('${tmp.path}/content/Ideas/note.txt').readAsStringSync(),
        'original',
      );
    });

    test('a body over the Content-Length limit is rejected before parsing',
        () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          maxUploadSizeBytes: 10,
          headers: {'content-length': '1000'},
        ),
      );

      expect(res.statusCode, HttpStatus.requestEntityTooLarge);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'payload_too_large');
    });

    test(
        'a stream exceeding the configured limit returns 413 and leaves '
        'no partial file', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          maxUploadSizeBytes: 3,
          formData: _formData(fields: {'path': ''}),
        ),
      );

      expect(res.statusCode, HttpStatus.requestEntityTooLarge);
      expect(
        Directory('${tmp.path}/content').existsSync()
            ? Directory('${tmp.path}/content').listSync().whereType<File>()
            : const <File>[],
        isEmpty,
      );
    });

    test('an invalid path segment returns 400', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          formData: _formData(fields: {'path': 'Projects/../etc'}),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('a missing path field returns 400', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          formData: _formData(fields: {}),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('a missing file part returns 400', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          formData: _formData(fields: {'path': ''}, fileFieldName: null),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('a non-multipart body returns 400', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          attachmentStore: store,
          formDataError: StateError('not multipart'),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
    });
  });
}
