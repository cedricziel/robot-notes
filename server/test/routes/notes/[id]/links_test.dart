import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/[id]/links.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required MetaIndex metaIndex,
  required LinkIndex linkIndex,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/notes/x/links'));
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<MetaIndex>()).thenReturn(metaIndex);
  when(() => ctx.read<LinkIndex>()).thenReturn(linkIndex);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-links-route-test-');

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

  test('shows resolved and unresolved outgoing links', () async {
    await _write(
      storage,
      meta,
      links,
      title: 'Existing Note',
      content: '',
    );
    final a = await _write(
      storage,
      meta,
      links,
      title: 'Source',
      content: '[[Existing Note]] and [[Missing Note]]',
    );
    final existing = meta.resolveTitle('Existing Note');

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: meta, linkIndex: links),
      a.id,
    );

    expect(res.statusCode, HttpStatus.ok);
    final body = await res.json() as Map<String, dynamic>;
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items, hasLength(2));

    final resolvedItem = items.firstWhere((i) => i['title'] == 'Existing Note');
    expect(resolvedItem['resolved'], isTrue);
    expect(resolvedItem['id'], existing);

    final unresolvedItem =
        items.firstWhere((i) => i['title'] == 'Missing Note');
    expect(unresolvedItem['resolved'], isFalse);
    expect(unresolvedItem.containsKey('id'), isFalse);
  });

  test('a note with no links returns an empty items list', () async {
    final a =
        await _write(storage, meta, links, title: 'Empty', content: 'text');

    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: meta, linkIndex: links),
      a.id,
    );

    final body = await res.json() as Map<String, dynamic>;
    expect(body['items'], isEmpty);
  });

  test(
      'a phantom link becomes resolved once the target is created, without '
      're-saving the linking note', () async {
    final a = await _write(
      storage,
      meta,
      links,
      title: 'Source',
      content: '[[Not Yet Written]]',
    );

    final before = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: meta, linkIndex: links),
      a.id,
    );
    final beforeItems =
        (await before.json() as Map<String, dynamic>)['items'] as List;
    expect((beforeItems.single as Map)['resolved'], isFalse);

    final target = await _write(
      storage,
      meta,
      links,
      title: 'Not Yet Written',
      content: '',
    );

    final after = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: meta, linkIndex: links),
      a.id,
    );
    final afterItems =
        (await after.json() as Map<String, dynamic>)['items'] as List;
    final afterItem = afterItems.single as Map;
    expect(afterItem['resolved'], isTrue);
    expect(afterItem['id'], target.id);
  });

  test('unknown note id returns 404', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.get, metaIndex: meta, linkIndex: links),
      'does-not-exist',
    );
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('disallowed method returns 405', () async {
    final res = await route.onRequest(
      _ctx(method: HttpMethod.post, metaIndex: meta, linkIndex: links),
      'anything',
    );
    expect(res.statusCode, HttpStatus.methodNotAllowed);
  });
}
