import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/knowledge_reads.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../routes/search.dart' as route;
import '../knowledge_test_context.dart' as knowledge_fixture;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required SearchIndex searchIndex,
  Uri? uri,
}) {
  final ctx = _MockRequestContext();
  when(() => ctx.read<KnowledgeReadService>())
      .thenReturn(knowledge_fixture.fixtureReads);
  when(() => ctx.read<NoteAuthorizationService>())
      .thenReturn(knowledge_fixture.fixtureAuthorization);
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(uri ?? Uri.parse('/search'));
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<SearchIndex>()).thenReturn(searchIndex);
  return ctx;
}

Directory _tempDir() {
  return Directory.systemTemp.createTempSync('robot-notes-search-route-test-');
}

Future<SearchIndex> _emptyIndex(Directory tmp) {
  return SearchIndex.open(
    dbFile: File('${tmp.path}/search.db'),
    storage: Storage(contentDir: Directory('${tmp.path}/content')),
  );
}

void main() {
  late Directory tmp;

  knowledge_fixture.authorizedSetUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('GET /search', () {
    knowledge_fixture.authorizedTest('returns ranked items for q=foo',
        () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);
      final stamp = DateTime.utc(2026, 3, 4, 5, 6);
      index
        ..upsert(id: 'a', title: 'A', content: 'foo bar', updatedAt: stamp)
        ..upsert(
          id: 'b',
          title: 'B',
          content: 'foo foo foo more foo',
          updatedAt: stamp,
        );

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search?q=foo'),
        ),
      );

      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      final items = body['items']! as List<dynamic>;
      expect(items, hasLength(2));
      // The repeat-heavy note should rank first.
      expect((items.first as Map<String, dynamic>)['id'], 'b');
      final first = items.first as Map<String, dynamic>;
      expect(
        first.keys,
        containsAll(['id', 'title', 'snippet', 'rank', 'updated_at']),
      );
      expect(first['updated_at'], stamp.toIso8601String());
    });

    knowledge_fixture.authorizedTest('missing q returns 400 missing_query',
        () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search'),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'missing_query');
    });

    knowledge_fixture.authorizedTest('empty q returns 400 empty_query',
        () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search?q='),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'empty_query');
    });

    knowledge_fixture.authorizedTest('whitespace-only q is treated as empty',
        () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search?q=%20%20'),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'empty_query');
    });

    knowledge_fixture.authorizedTest('limit defaults to 20 and clamps at 100',
        () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);
      for (var i = 0; i < 25; i++) {
        index.upsert(
          id: 'n$i',
          title: 't$i',
          content: 'orbit',
          updatedAt: DateTime.utc(2026),
        );
      }

      // No limit → defaults to 20.
      final defaultRes = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search?q=orbit'),
        ),
      );
      final defaultBody = await defaultRes.json() as Map<String, dynamic>;
      expect(defaultBody['items']! as List<dynamic>, hasLength(20));
      expect(defaultBody['limit'], 20);

      // limit=999 → clamps to 100.
      final clampRes = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search?q=orbit&limit=999'),
        ),
      );
      final clampBody = await clampRes.json() as Map<String, dynamic>;
      expect(clampBody['limit'], 100);
    });

    knowledge_fixture.authorizedTest(
        'non-positive or non-numeric limit returns 400', () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);

      for (final bad in ['0', '-1', 'abc']) {
        final res = await route.onRequest(
          _ctx(
            method: HttpMethod.get,
            searchIndex: index,
            uri: Uri.parse('/search?q=foo&limit=$bad'),
          ),
        );
        expect(
          res.statusCode,
          HttpStatus.badRequest,
          reason: 'limit=$bad should reject',
        );
      }
    });

    knowledge_fixture.authorizedTest(
        'invalid FTS query returns 400 invalid_query', () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search?q=%22unterminated'),
        ),
      );

      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'invalid_query');
    });

    knowledge_fixture.authorizedTest('path filter narrows results to a folder',
        () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);
      final stamp = DateTime.utc(2026);
      index
        ..upsert(
          id: 'a',
          title: 'A',
          content: 'budget plan',
          updatedAt: stamp,
          path: 'Projects/Alpha',
        )
        ..upsert(id: 'b', title: 'B', content: 'budget plan', updatedAt: stamp);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search?q=budget&path=Projects/Alpha'),
        ),
      );

      final body = await res.json() as Map<String, dynamic>;
      final items = (body['items'] as List).cast<Map<String, dynamic>>();
      expect(items.map((i) => i['id']), ['a']);
    });

    knowledge_fixture.authorizedTest(
        'tag filter narrows results to notes carrying the tag', () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);
      final stamp = DateTime.utc(2026);
      index
        ..upsert(
          id: 'a',
          title: 'A',
          content: 'budget plan',
          updatedAt: stamp,
          tags: {'finance'},
        )
        ..upsert(id: 'b', title: 'B', content: 'budget plan', updatedAt: stamp);

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          searchIndex: index,
          uri: Uri.parse('/search?q=budget&tag=finance'),
        ),
      );

      final body = await res.json() as Map<String, dynamic>;
      final items = (body['items'] as List).cast<Map<String, dynamic>>();
      expect(items.map((i) => i['id']), ['a']);
    });

    knowledge_fixture.authorizedTest('non-GET methods return 405', () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);

      for (final m in [
        HttpMethod.post,
        HttpMethod.put,
        HttpMethod.delete,
        HttpMethod.patch,
      ]) {
        final res = await route.onRequest(
          _ctx(method: m, searchIndex: index),
        );
        expect(
          res.statusCode,
          HttpStatus.methodNotAllowed,
          reason: '$m should be 405',
        );
      }
    });
  });
}
