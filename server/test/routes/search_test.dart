import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '../../routes/search.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required SearchIndex searchIndex,
  Uri? uri,
}) {
  final ctx = _MockRequestContext();
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

  setUp(() {
    tmp = _tempDir();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('GET /search', () {
    test('returns ranked items for q=foo', () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);
      index
        ..upsert(id: 'a', title: 'A', content: 'foo bar')
        ..upsert(id: 'b', title: 'B', content: 'foo foo foo more foo');

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
      expect(first.keys, containsAll(['id', 'title', 'snippet', 'rank']));
    });

    test('missing q returns 400 missing_query', () async {
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

    test('empty q returns 400 empty_query', () async {
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

    test('whitespace-only q is treated as empty', () async {
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

    test('limit defaults to 20 and clamps at 100', () async {
      final index = await _emptyIndex(tmp);
      addTearDown(index.close);
      for (var i = 0; i < 25; i++) {
        index.upsert(id: 'n$i', title: 't$i', content: 'orbit');
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

    test('non-positive or non-numeric limit returns 400', () async {
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

    test('invalid FTS query returns 400 invalid_query', () async {
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

    test('non-GET methods return 405', () async {
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
