import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '_test_app.dart';

void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.start();
  });
  tearDown(() => app.close());

  test('append route persists text on the addressed note', () async {
    final created = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(),
      body: jsonEncode({'title': 'Diary', 'content': 'first'}),
    );
    expect(created.statusCode, 201, reason: created.body);
    final id = (jsonDecode(created.body) as Map<String, dynamic>)['id'];

    final appended = await http.post(
      Uri.parse('${app.baseUrl}/notes/$id/append'),
      headers: app.headers(),
      body: jsonEncode({'content': 'second'}),
    );
    expect(appended.statusCode, 200, reason: appended.body);
    final read = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: app.headers(),
    );
    expect((jsonDecode(read.body) as Map)['content'], 'first\nsecond');
  });

  test('tree route creates and lists an empty folder', () async {
    final created = await http.post(
      Uri.parse('${app.baseUrl}/notes/tree'),
      headers: app.headers(),
      body: jsonEncode({'path': 'Ideas'}),
    );
    expect(created.statusCode, 201, reason: created.body);

    final tree = await http.get(
      Uri.parse('${app.baseUrl}/notes/tree'),
      headers: app.headers(),
    );
    expect(tree.statusCode, 200, reason: tree.body);
    expect((jsonDecode(tree.body) as Map)['folders'], [
      {'path': 'Ideas', 'note_count': 0, 'file_count': 0},
    ]);
  });

  test('file routes upload, list, and download a nested file', () async {
    final upload = http.MultipartRequest(
      'POST',
      Uri.parse('${app.baseUrl}/notes/files'),
    )
      ..headers['Authorization'] = app.headers()['Authorization']!
      ..fields['path'] = 'Ideas'
      ..files.add(
        http.MultipartFile.fromString(
          'file',
          'diagram contents',
          filename: 'diagram.txt',
        ),
      );
    final uploaded = await http.Response.fromStream(await upload.send());
    expect(uploaded.statusCode, 201, reason: uploaded.body);

    final listed = await http.get(
      Uri.parse('${app.baseUrl}/notes/files?path=Ideas'),
      headers: app.headers(),
    );
    expect(listed.statusCode, 200, reason: listed.body);
    expect((jsonDecode(listed.body) as Map)['items'], [
      containsPair('filename', 'diagram.txt'),
    ]);
    final downloaded = await http.get(
      Uri.parse('${app.baseUrl}/notes/files/Ideas/diagram.txt'),
      headers: app.headers(),
    );
    expect(downloaded.statusCode, 200, reason: downloaded.body);
    expect(downloaded.body, 'diagram contents');
  });

  test('link routes resolve a target and return its referring note', () async {
    final target = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(),
      body: jsonEncode({'title': 'Target', 'content': ''}),
    );
    final source = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(),
      body: jsonEncode({'title': 'Source', 'content': 'See [[Target]]'}),
    );
    expect(target.statusCode, 201, reason: target.body);
    expect(source.statusCode, 201, reason: source.body);
    final targetId = (jsonDecode(target.body) as Map)['id'];
    final sourceId = (jsonDecode(source.body) as Map)['id'];

    final outgoing = await http.get(
      Uri.parse('${app.baseUrl}/notes/$sourceId/links'),
      headers: app.headers(),
    );
    expect(outgoing.statusCode, 200, reason: outgoing.body);
    expect((jsonDecode(outgoing.body) as Map)['items'], [
      {'title': 'Target', 'resolved': true, 'id': targetId},
    ]);
    final incoming = await http.get(
      Uri.parse('${app.baseUrl}/notes/$targetId/backlinks'),
      headers: app.headers(),
    );
    expect(incoming.statusCode, 200, reason: incoming.body);
    expect((jsonDecode(incoming.body) as Map)['items'], [
      containsPair('id', sourceId),
    ]);
  });

  test('tags route returns tags indexed from note content', () async {
    final created = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(),
      body: jsonEncode({'title': 'Tagged', 'content': '#ideas'}),
    );
    expect(created.statusCode, 201, reason: created.body);

    final tags = await http.get(
      Uri.parse('${app.baseUrl}/tags'),
      headers: app.headers(),
    );
    expect(tags.statusCode, 200, reason: tags.body);
    expect((jsonDecode(tags.body) as Map)['items'], [
      {'tag': 'ideas', 'count': 1},
    ]);
  });

  test('telemetry configuration is reachable without authentication', () async {
    final response = await http.get(Uri.parse('${app.baseUrl}/otel-config'));

    expect(response.statusCode, 200, reason: response.body);
    expect(jsonDecode(response.body), {'enabled': false});
    expect(response.headers['cache-control'], 'no-store');
  });

  test('static bundle is public while API requests still require auth',
      () async {
    final web = await Directory.systemTemp.createTemp('robot-notes-web-test-');
    addTearDown(() => web.delete(recursive: true));
    await File('${web.path}/index.html').writeAsString('test web bundle');
    final webApp = await TestApp.start(webDir: web.path);
    addTearDown(webApp.close);

    final page = await http.get(Uri.parse('${webApp.baseUrl}/'));
    expect(page.statusCode, 200, reason: page.body);
    expect(page.body, 'test web bundle');
    final api = await http.get(Uri.parse('${webApp.baseUrl}/notes'));
    expect(api.statusCode, 401, reason: api.body);
  });
}
