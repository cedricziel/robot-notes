import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/[id]/backlinks.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required Storage storage,
  required MetaIndex metaIndex,
  required LinkIndex linkIndex,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/notes/x/backlinks'));
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Storage>()).thenReturn(storage);
  when(() => ctx.read<MetaIndex>()).thenReturn(metaIndex);
  when(() => ctx.read<LinkIndex>()).thenReturn(linkIndex);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-backlinks-route-test-');

/// Mirrors what NoteWriteService wires on every create/update, without
/// pulling in search/broadcast machinery this route doesn't touch.
Future<StoredNote> _write(
  Storage storage,
  MetaIndex meta,
  LinkIndex links, {
  required String title,
  required String content,
}) async {
  final note = await storage.create(title: title, content: content);
  meta.upsert(note.toSummary());
  links.upsert(note.id, note.content);
  return note;
}

void main() {
  late Directory tmp;
  late Storage storage;
  late MetaIndex meta;
  late LinkIndex links;

  setUp(() {
    tmp = _tempDir();
    storage = Storage(
      contentDir: Directory('${tmp.path}/content'),
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
    meta = MetaIndex();
    links = LinkIndex();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('lists every note whose content links to the given note', () async {
    final a = await _write(storage, meta, links, title: 'Alpha', content: '');
    final b = await _write(
      storage,
      meta,
      links,
      title: 'Beta',
      content: 'refers to [[Alpha]]',
    );
    final c = await _write(
      storage,
      meta,
      links,
      title: 'Gamma',
      content: 'also mentions [[Alpha|the plan]]',
    );

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.get,
        storage: storage,
        metaIndex: meta,
        linkIndex: links,
      ),
      a.id,
    );

    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items.map((i) => i['id']).toSet(), {b.id, c.id});
    for (final item in items) {
      expect(item['title'], isA<String>());
      expect(item['snippet'], isA<String>());
      expect((item['snippet'] as String).contains('Alpha'), isTrue);
    }
  });

  test('a note with no backlinks returns an empty items list', () async {
    final a = await _write(storage, meta, links, title: 'Lonely', content: '');

    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.get,
        storage: storage,
        metaIndex: meta,
        linkIndex: links,
      ),
      a.id,
    );

    final body = await res.json() as Map<String, dynamic>;
    expect(body['items'], isEmpty);
  });

  test('unknown note id returns 404', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.get,
        storage: storage,
        metaIndex: meta,
        linkIndex: links,
      ),
      'does-not-exist',
    );
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(
        method: HttpMethod.post,
        storage: storage,
        metaIndex: meta,
        linkIndex: links,
      ),
      'anything',
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });
}
