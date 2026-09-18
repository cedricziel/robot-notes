import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server/src/app_deps.dart';
import 'package:server/src/config.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '_test_app.dart';

/// End-to-end database scenarios driven over the real HTTP surface, per
/// task 7.2: a moved note leaves its database on the next query, a source
/// change takes effect on the next query, a property written via `PUT` is
/// queryable immediately, a search-index rebuild after a schema bump
/// restores property queries, and a malformed `type: database` note is
/// never returned as a row.
void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.start();
  });

  tearDown(() async {
    await app.close();
  });

  Future<Map<String, dynamic>> createDatabase({
    required String title,
    Map<String, dynamic>? source,
    String path = '',
    Map<String, dynamic> properties = const {},
  }) async {
    final res = await http.post(
      Uri.parse('${app.baseUrl}/databases'),
      headers: app.headers(),
      body: jsonEncode({
        'title': title,
        if (source != null) 'source': source,
        'path': path,
        'properties': properties,
      }),
    );
    expect(res.statusCode, 201, reason: res.body);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createRow({
    required String databaseId,
    required String title,
    Map<String, dynamic> properties = const {},
    String? path,
  }) async {
    final res = await http.post(
      Uri.parse('${app.baseUrl}/databases/$databaseId/rows'),
      headers: app.headers(),
      body: jsonEncode({
        'title': title,
        'properties': properties,
        if (path != null) 'path': path,
      }),
    );
    expect(res.statusCode, 201, reason: res.body);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> query(
    String databaseId, {
    Map<String, dynamic>? filter,
  }) async {
    final res = await http.post(
      Uri.parse('${app.baseUrl}/databases/$databaseId/query'),
      headers: app.headers(),
      body: jsonEncode({if (filter != null) 'filter': filter}),
    );
    expect(res.statusCode, 200, reason: res.body);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  List<String> idsOf(Map<String, dynamic> page) =>
      (page['items'] as List).map((i) => (i as Map)['id'] as String).toList();

  test('a moved note leaves the database on the next query', () async {
    final db = await createDatabase(
      title: 'Projects',
      source: {'folder': 'Projects', 'include_subfolders': true},
    );
    final row = await createRow(
      databaseId: db['id'] as String,
      title: 'Alpha',
      path: 'Projects',
    );

    final before = await query(db['id'] as String);
    expect(idsOf(before), [row['id']]);

    // Move the row's note out of the database's folder.
    final moveRes = await http.put(
      Uri.parse('${app.baseUrl}/notes/${row['id']}'),
      headers: {...app.headers(), 'If-Match': '${row['version']}'},
      body: jsonEncode({
        'title': 'Alpha',
        'content': '',
        'path': 'Elsewhere',
      }),
    );
    expect(moveRes.statusCode, 200, reason: moveRes.body);

    final after = await query(db['id'] as String);
    expect(idsOf(after), isEmpty);
  });

  test('a source change takes effect on the next query', () async {
    final db = await createDatabase(
      title: 'Team',
      source: {'folder': 'Team', 'include_subfolders': true},
    );
    final row = await createRow(
      databaseId: db['id'] as String,
      title: 'Bob',
      path: 'Team',
    );

    final before = await query(db['id'] as String);
    expect(idsOf(before), [row['id']]);

    final updateRes = await http.put(
      Uri.parse('${app.baseUrl}/databases/${db['id']}'),
      headers: {...app.headers(), 'If-Match': '${db['version']}'},
      body: jsonEncode({
        'source': {'folder': 'Other', 'include_subfolders': true},
      }),
    );
    expect(updateRes.statusCode, 200, reason: updateRes.body);

    final after = await query(db['id'] as String);
    expect(
      idsOf(after),
      isEmpty,
      reason: 'the row still lives under Team, which is no longer covered',
    );
  });

  test('a property written via PUT is queryable immediately', () async {
    final db = await createDatabase(
      title: 'Board',
      source: {'folder': 'Board', 'include_subfolders': true},
      properties: {
        'status': {
          'type': 'select',
          'options': ['todo', 'done'],
        },
      },
    );
    final row = await createRow(
      databaseId: db['id'] as String,
      title: 'Task 1',
      path: 'Board',
      properties: {'status': 'todo'},
    );

    final updateRes = await http.put(
      Uri.parse('${app.baseUrl}/notes/${row['id']}'),
      headers: {...app.headers(), 'If-Match': '${row['version']}'},
      body: jsonEncode({
        'title': 'Task 1',
        'content': '',
        'properties': {'status': 'done'},
      }),
    );
    expect(updateRes.statusCode, 200, reason: updateRes.body);

    final done = await query(
      db['id'] as String,
      filter: {'property': 'status', 'op': 'eq', 'value': 'done'},
    );
    expect(idsOf(done), [row['id']]);

    final todo = await query(
      db['id'] as String,
      filter: {'property': 'status', 'op': 'eq', 'value': 'todo'},
    );
    expect(idsOf(todo), isEmpty);
  });

  test('index rebuild after a schema bump restores property queries', () async {
    final db = await createDatabase(
      title: 'Rebuild',
      source: {'folder': 'Rebuild', 'include_subfolders': true},
      properties: {
        'status': {
          'type': 'select',
          'options': ['todo', 'done'],
        },
      },
    );
    final row = await createRow(
      databaseId: db['id'] as String,
      title: 'Survives',
      path: 'Rebuild',
      properties: {'status': 'todo'},
    );

    final dataDir = app.tmpDir.path;
    await app.close(deleteDir: false);
    addTearDown(() {
      final dir = Directory(dataDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    // Simulate a schema bump: mark the on-disk search.db as an older,
    // now-stale schema version so the next open treats it as unhealthy
    // and rebuilds it from the vault on disk.
    final dbFile = File('$dataDir/search.db');
    sqlite3.open(dbFile.path)
      ..execute("UPDATE meta SET value = '1' WHERE key = 'schema_version';")
      ..close();

    final config = Config(
      apiKey: 'integration-key',
      dataDir: dataDir,
      port: 0,
      lockTtlSeconds: 60,
    );
    final deps = await AppDeps.bootstrap(config);
    final server = await startTestServer(deps: deps, config: config);
    app = TestApp.wrap(server, deps, config, Directory(dataDir));

    final page = await http.post(
      Uri.parse('${app.baseUrl}/databases/${db['id']}/query'),
      headers: app.headers(),
      body: jsonEncode({
        'filter': {'property': 'status', 'op': 'eq', 'value': 'todo'},
      }),
    );
    expect(page.statusCode, 200, reason: page.body);
    final body = jsonDecode(page.body) as Map<String, dynamic>;
    expect(
      (body['items'] as List).map((i) => (i as Map)['id']),
      [row['id']],
    );
  });

  test('a malformed type: database note is never a row', () async {
    final db = await createDatabase(title: 'Root');

    // Write a note with `type: database` frontmatter that fails semantic
    // validation (a `select` property with duplicate options) directly to
    // disk, bypassing the write path's own validation — the same way an
    // externally-edited vault file could arrive.
    final noteFile = File('${app.tmpDir.path}/content/Broken.md');
    noteFile.writeAsStringSync('''
---
id: "broken-def-1"
title: "Broken"
path: ""
version: 1
created_at: "2026-01-01T00:00:00.000Z"
updated_at: "2026-01-01T00:00:00.000Z"
type: "database"
properties:
  status:
    type: "select"
    options:
      - "todo"
      - "todo"
---

''');

    final dataDir = app.tmpDir.path;
    await app.close(deleteDir: false);
    addTearDown(() {
      final dir = Directory(dataDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final config = Config(
      apiKey: 'integration-key',
      dataDir: dataDir,
      port: 0,
      lockTtlSeconds: 60,
    );
    final deps = await AppDeps.bootstrap(config);
    final server = await startTestServer(deps: deps, config: config);
    app = TestApp.wrap(server, deps, config, Directory(dataDir));

    // Not registered as a database.
    final list = await http.get(
      Uri.parse('${app.baseUrl}/databases'),
      headers: app.headers(),
    );
    expect(list.statusCode, 200, reason: list.body);
    final listed = (jsonDecode(list.body) as Map)['items'] as List;
    expect(
      listed.map((i) => (i as Map)['id']),
      isNot(contains('broken-def-1')),
    );

    // Never surfaced as a row of the covering database either.
    final page = await http.post(
      Uri.parse('${app.baseUrl}/databases/${db['id']}/query'),
      headers: app.headers(),
    );
    expect(page.statusCode, 200, reason: page.body);
    final items = (jsonDecode(page.body) as Map)['items'] as List;
    expect(
      items.map((i) => (i as Map)['id']),
      isNot(contains('broken-def-1')),
    );
  });
}
