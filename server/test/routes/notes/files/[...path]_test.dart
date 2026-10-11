import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/knowledge_reads.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/files/[...path].dart' as route;
import '../../../knowledge_test_context.dart' as knowledge_fixture;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({required HttpMethod method, required Storage storage}) {
  final ctx = _MockRequestContext();
  when(() => ctx.read<KnowledgeReadService>())
      .thenReturn(knowledge_fixture.fixtureReads);
  when(() => ctx.read<NoteAuthorizationService>())
      .thenReturn(knowledge_fixture.fixtureAuthorization);
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Storage>()).thenReturn(storage);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-files-path-test-');

void main() {
  late Directory tmp;
  late Storage storage;

  knowledge_fixture.authorizedSetUp(() {
    tmp = _tempDir();
    storage = Storage(contentDir: Directory('${tmp.path}/content'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  knowledge_fixture.authorizedTest(
      'retrieves a previously uploaded file with the right content-type',
      () async {
    final dir = Directory('${tmp.path}/content/Ideas')
      ..createSync(recursive: true);
    File('${dir.path}/diagram.png').writeAsBytesSync([1, 2, 3]);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'Ideas/diagram.png',
    );

    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers['content-type'], 'image/png');
    final bytes = await res.bytes().expand((c) => c).toList();
    expect(bytes, [1, 2, 3]);
  });

  knowledge_fixture.authorizedTest('a nested path resolves correctly',
      () async {
    final dir = Directory('${tmp.path}/content/Projects/Alpha')
      ..createSync(recursive: true);
    File('${dir.path}/notes.pdf').writeAsStringSync('hello');

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'Projects/Alpha/notes.pdf',
    );

    expect(res.statusCode, HttpStatus.ok);
    expect(utf8.decode(await res.bytes().expand((c) => c).toList()), 'hello');
  });

  knowledge_fixture.authorizedTest('a path with no file returns 404', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'does-not-exist.png',
    );

    expect(res.statusCode, HttpStatus.notFound);
  });

  knowledge_fixture.authorizedTest(
      'an unrecognized extension falls back to application/octet-stream',
      () async {
    Directory('${tmp.path}/content').createSync(recursive: true);
    File('${tmp.path}/content/mystery.nonexistentextension')
        .writeAsBytesSync([1]);

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'mystery.nonexistentextension',
    );

    expect(res.headers['content-type'], 'application/octet-stream');
  });

  knowledge_fixture.authorizedTest('a traversal attempt is rejected with 400',
      () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, storage: storage),
      'Projects/../etc',
    );

    expect(res.statusCode, HttpStatus.badRequest);
  });

  knowledge_fixture.authorizedTest('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, storage: storage),
      'diagram.png',
    );

    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });
  knowledge_fixture.authorizedTest(
      'does not stream canonical content from a faulted history commit',
      () async {
    final note = await storage.create(
      title: 'A',
      content: 'accepted',
      properties: {'history': true},
    );
    storage = Storage(
      contentDir: Directory('${tmp.path}/content'),
      afterHistoryPublish: () async => throw StateError('crash'),
    );
    await expectLater(
      storage.update(
        id: note.id,
        title: 'A',
        content: 'uncommitted',
        ifMatch: 1,
      ),
      throwsStateError,
    );
    await expectLater(
      route.onRequest(
        _ctx(method: HttpMethod.get, storage: storage),
        'A.md',
      ),
      throwsStateError,
    );
  });
}
