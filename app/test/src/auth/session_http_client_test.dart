import 'package:app/src/auth/session_http_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const oldConfig = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'old',
  actor: 'Alice',
  oauthClientId: 'client',
  oauthRefreshToken: 'refresh',
);
const newConfig = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'new',
  actor: 'Alice',
  oauthClientId: 'client',
  oauthRefreshToken: 'rotated',
);

void main() {
  test(
    'retries rejected writes with renewed credentials and identical body',
    () async {
      var config = oldConfig;
      final bodies = <String>[];
      final client = SessionHttpClient(
        inner: MockClient((request) async {
          expect(request.headers['If-Match'], 'version-1');
          bodies.add(request.body);
          return http.Response(
            '',
            request.headers['Authorization'] == 'Bearer new' ? 204 : 401,
          );
        }),
        config: () => config,
        renew: (_) async => config = newConfig,
        onExpired: () => fail('Session should renew'),
      );
      addTearDown(client.close);
      final response = await client.put(
        Uri.parse('${config.baseUrl}/notes/1'),
        headers: {'If-Match': 'version-1'},
        body: 'draft',
      );
      expect(response.statusCode, 204);
      expect(bodies, ['draft', 'draft']);
    },
  );

  test(
    'does not retry forever when renewed credentials are rejected',
    () async {
      var expired = false;
      var config = oldConfig;
      var attempts = 0;
      final client = SessionHttpClient(
        inner: MockClient((_) async {
          attempts++;
          return http.Response('', 401);
        }),
        config: () => config,
        renew: (_) async => config = newConfig,
        onExpired: () => expired = true,
      );
      addTearDown(client.close);
      expect(
        (await client.get(Uri.parse('${config.baseUrl}/notes'))).statusCode,
        401,
      );
      expect(attempts, 2);
      expect(expired, isTrue);
    },
  );

  test('manual keys show sign-in without attempting OAuth refresh', () async {
    var expired = false;
    final client = SessionHttpClient(
      inner: MockClient((_) async => http.Response('', 401)),
      config: () => const AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'key',
        actor: 'Alice',
      ),
      renew: (_) async {
        fail('Manual keys cannot refresh');
      },
      onExpired: () => expired = true,
    );
    addTearDown(client.close);
    await client.get(Uri.parse('https://notes.example/notes'));
    expect(expired, isTrue);
  });
}
