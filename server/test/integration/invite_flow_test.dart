import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '_test_app.dart';

/// End-to-end agent onboarding:
///   1. Operator (already authed) mints an invite via `POST /invites`.
///   2. Agent (no key yet) GETs `/invites/{token}/onboarding.txt` once.
///   3. Second GET returns 410 Gone.
///   4. Agent uses the API key parsed from the bundle to GET `/notes`.
void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.start();
  });

  tearDown(() async {
    await app.close();
  });

  test('mint -> fetch -> burn -> use returned key against /notes', () async {
    // 1. Operator mints an invite.
    final mintRes = await http.post(
      Uri.parse('${app.baseUrl}/invites'),
      headers: app.headers(actor: 'operator'),
      body: jsonEncode({'label': 'starter-bot'}),
    );
    expect(mintRes.statusCode, 201, reason: mintRes.body);
    final mint = jsonDecode(mintRes.body) as Map<String, dynamic>;
    final token = mint['token'] as String;
    final onboardingUrl = mint['url'] as String;
    expect(onboardingUrl, endsWith('/invites/$token/onboarding.txt'));

    // 2. Agent fetches the bundle (no auth header at all).
    final firstRes = await http.get(Uri.parse(onboardingUrl));
    expect(firstRes.statusCode, 200, reason: firstRes.body);
    expect(
      firstRes.headers['content-type'],
      contains('text/plain'),
    );
    final bundle = firstRes.body;
    expect(bundle, contains('robot-notes onboarding'));
    expect(bundle, contains(app.config.apiKey));

    // 3. Second fetch is 410 Gone.
    final secondRes = await http.get(Uri.parse(onboardingUrl));
    expect(secondRes.statusCode, 410);
    final secondBody = jsonDecode(secondRes.body) as Map<String, dynamic>;
    expect(secondBody['error'], 'invite_burned');

    // 4. Parse the bundle for the api key, prove it works against /notes.
    final apiKey = _parseApiKey(bundle);
    expect(apiKey, app.config.apiKey);

    final notesRes = await http.get(
      Uri.parse('${app.baseUrl}/notes'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'X-Actor': 'starter-bot',
      },
    );
    expect(notesRes.statusCode, 200, reason: notesRes.body);
    final notesBody = jsonDecode(notesRes.body) as Map<String, dynamic>;
    expect(notesBody.containsKey('items'), isTrue);
  });
}

String _parseApiKey(String bundle) {
  final line =
      bundle.split('\n').firstWhere((l) => l.startsWith('API key (Bearer):'));
  return line.split(':').last.trim();
}
