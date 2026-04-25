import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '_test_app.dart';

/// Optimistic-concurrency control under simulated parallelism: two PUT
/// requests with the same `If-Match` header must yield exactly one 200
/// and one 409, with the 409 carrying the post-write current state.
void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.start();
  });

  tearDown(() async {
    await app.close();
  });

  test('two parallel PUTs with the same If-Match: one wins, one gets 409',
      () async {
    final createRes = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(actor: 'alice'),
      body: jsonEncode({'title': 'race', 'content': 'start'}),
    );
    expect(createRes.statusCode, 201);
    final id =
        (jsonDecode(createRes.body) as Map<String, dynamic>)['id'] as String;

    Future<http.Response> attempt(String body) => http.put(
          Uri.parse('${app.baseUrl}/notes/$id'),
          headers: {
            ...app.headers(actor: 'alice'),
            'If-Match': '1',
          },
          body: jsonEncode({'title': 'race', 'content': body}),
        );

    final results = await Future.wait([
      attempt('first writer'),
      attempt('second writer'),
    ]);

    final statuses = results.map((r) => r.statusCode).toList()..sort();
    expect(statuses, [200, 409]);

    final winner = results.firstWhere((r) => r.statusCode == 200);
    final loser = results.firstWhere((r) => r.statusCode == 409);

    final winBody = jsonDecode(winner.body) as Map<String, dynamic>;
    expect(winBody['version'], 2);

    final loseBody = jsonDecode(loser.body) as Map<String, dynamic>;
    expect(loseBody['error'], 'version_conflict');
    final current = loseBody['current'] as Map<String, dynamic>;
    expect(current['version'], 2);
    expect(current['content'], winBody['content']);
  });
}
