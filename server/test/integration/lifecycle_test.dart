import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '_test_app.dart';

/// End-to-end lifecycle of a single note over the real HTTP surface:
/// create -> read -> lock -> update -> search -> delete.
///
/// Every other unit test stubs at least one collaborator. This is the
/// single test that proves the production wiring (config, AppDeps,
/// middleware order, router tree, atomic writes) holds together when
/// driven by an actual TCP-level HTTP client.
void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.start();
  });

  tearDown(() async {
    await app.close();
  });

  test('create -> read -> lock -> update -> search -> delete', () async {
    // 1. CREATE
    final createRes = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(actor: 'alice'),
      body: jsonEncode({
        'title': 'Mars rover diary',
        'content': 'sol 42 dust storm rolling in',
      }),
    );
    expect(createRes.statusCode, 201, reason: createRes.body);
    final created = jsonDecode(createRes.body) as Map<String, dynamic>;
    final id = created['id'] as String;
    expect(created['version'], 1);
    expect(created['title'], 'Mars rover diary');

    // 2. READ
    final readRes = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: app.headers(actor: 'alice'),
    );
    expect(readRes.statusCode, 200, reason: readRes.body);
    final read = jsonDecode(readRes.body) as Map<String, dynamic>;
    expect(read['content'], 'sol 42 dust storm rolling in');
    expect(read['lock'], isNull);

    // 3. LIST sees it
    final listRes = await http.get(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(actor: 'alice'),
    );
    expect(listRes.statusCode, 200);
    final list = jsonDecode(listRes.body) as Map<String, dynamic>;
    final items = list['items'] as List;
    expect(items, hasLength(1));
    expect((items.first as Map)['id'], id);

    // 4. LOCK
    final lockRes = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/lock'),
      headers: app.headers(actor: 'alice'),
    );
    expect(lockRes.statusCode, 200, reason: lockRes.body);
    final lock = jsonDecode(lockRes.body) as Map<String, dynamic>;
    expect(lock['holder'], 'alice');

    // GET reflects the lock
    final readLockedRes = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: app.headers(actor: 'alice'),
    );
    final readLocked = jsonDecode(readLockedRes.body) as Map<String, dynamic>;
    expect((readLocked['lock'] as Map)['holder'], 'alice');

    // 5. UPDATE (lock holder, with If-Match)
    final updateRes = await http.put(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: {
        ...app.headers(actor: 'alice'),
        'If-Match': '1',
      },
      body: jsonEncode({
        'title': 'Mars rover diary',
        'content': 'sol 43 dust cleared, panorama uploaded',
      }),
    );
    expect(updateRes.statusCode, 200, reason: updateRes.body);
    final updated = jsonDecode(updateRes.body) as Map<String, dynamic>;
    expect(updated['version'], 2);

    // 6. SEARCH finds the new term
    final searchRes = await http.get(
      Uri.parse('${app.baseUrl}/search?q=panorama'),
      headers: app.headers(actor: 'alice'),
    );
    expect(searchRes.statusCode, 200, reason: searchRes.body);
    final search = jsonDecode(searchRes.body) as Map<String, dynamic>;
    final hits = search['items'] as List;
    expect(hits, hasLength(1));
    expect((hits.first as Map)['id'], id);

    // SEARCH no longer finds the obsolete term.
    final staleRes = await http.get(
      Uri.parse('${app.baseUrl}/search?q=storm'),
      headers: app.headers(actor: 'alice'),
    );
    final stale = jsonDecode(staleRes.body) as Map<String, dynamic>;
    expect(stale['items'], isEmpty);

    // 7. DELETE
    final deleteRes = await http.delete(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: app.headers(actor: 'alice'),
    );
    expect(deleteRes.statusCode, 204);

    // GET now 404
    final goneRes = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: app.headers(actor: 'alice'),
    );
    expect(goneRes.statusCode, 404);

    // SEARCH no longer finds it.
    final searchGoneRes = await http.get(
      Uri.parse('${app.baseUrl}/search?q=panorama'),
      headers: app.headers(actor: 'alice'),
    );
    final searchGone = jsonDecode(searchGoneRes.body) as Map<String, dynamic>;
    expect(searchGone['items'], isEmpty);
  });

  test('healthz is reachable without auth', () async {
    final res = await http.get(Uri.parse('${app.baseUrl}/healthz'));
    expect(res.statusCode, 200);
    expect(jsonDecode(res.body), {'status': 'ok'});
  });

  test('protected route returns 401 without bearer', () async {
    final res = await http.get(Uri.parse('${app.baseUrl}/notes'));
    expect(res.statusCode, 401);
    expect(jsonDecode(res.body), {'error': 'unauthorized'});
  });

  test('protected route returns 401 with wrong key', () async {
    final res = await http.get(
      Uri.parse('${app.baseUrl}/notes'),
      headers: {'Authorization': 'Bearer not-the-key'},
    );
    expect(res.statusCode, 401);
  });
}
