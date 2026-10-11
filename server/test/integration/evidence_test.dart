import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '_oauth_test_helpers.dart';
import '_test_app.dart';

void main() {
  late TestApp app;
  const payload = '{"session_id":"session","kind":"turn","messages":'
      '[{"role":"tool","content":"archiveonlykeyword"}]}';
  final id = sha256.convert(utf8.encode(payload)).toString();
  setUp(() async => app = await TestApp.start());
  tearDown(() async => app.close());

  test('archive is isolated by vault and excluded from notes and search',
      () async {
    final created = await http.post(
      Uri.parse('${app.baseUrl}/vaults'),
      headers: app.headers(),
      body: jsonEncode({'name': 'Evidence vault'}),
    );
    final vault = (jsonDecode(created.body) as Map)['id'] as String;
    final headers = {...app.headers(), 'X-Vault-Id': vault};
    final write = await http.put(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: headers,
      body: jsonEncode({'payload': payload, 'retention_days': 7}),
    );
    expect(write.statusCode, 200, reason: write.body);
    final other = await http.get(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: app.headers(),
    );
    expect(other.statusCode, 404);
    final own = await http.get(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: headers,
    );
    expect(own.body, write.body);
    final notes =
        await http.get(Uri.parse('${app.baseUrl}/notes'), headers: headers);
    expect((jsonDecode(notes.body) as Map)['items'], isEmpty);
    final search = await http.get(
      Uri.parse('${app.baseUrl}/search?q=archiveonlykeyword'),
      headers: headers,
    );
    expect((jsonDecode(search.body) as Map)['items'], isEmpty);
  });

  test(
      'read-only OAuth cannot archive and vault grants restrict evidence reads',
      () async {
    final grant = await completeOAuthFlow(
      baseUrl: app.baseUrl,
      apiKey: app.config.apiKey,
      resource: app.baseUrl,
      scope: 'notes:read',
    );
    final headers = {'Authorization': 'Bearer ${grant.accessToken}'};
    final write = await http.put(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: headers,
      body: jsonEncode({'payload': payload, 'retention_days': 7}),
    );
    expect(write.statusCode, 403);
    final read = await http.get(
      Uri.parse('${app.baseUrl}/evidence/$id'),
      headers: {...headers, 'X-Vault-Id': 'outside-grant'},
    );
    expect(read.statusCode, 403);
  });
}
