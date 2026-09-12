import 'package:app/src/auth/loopback_redirect.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('LoopbackRedirectServer', () {
    test('redirectUri points at the bound ephemeral port', () async {
      final server = await LoopbackRedirectServer.bind();
      addTearDown(server.close);

      expect(server.redirectUri, 'http://127.0.0.1:${server.port}/callback');
      expect(server.port, greaterThan(0));
    });

    test('resolves with the code and state from the first request', () async {
      final server = await LoopbackRedirectServer.bind();
      addTearDown(server.close);

      final resultFuture = server.waitForCallback();
      final response = await http.get(
        Uri.parse(server.redirectUri).replace(
          queryParameters: {'code': 'auth-code-abc', 'state': 'state-xyz'},
        ),
      );
      expect(response.statusCode, 200);

      final result = await resultFuture;
      expect(result.code, 'auth-code-abc');
      expect(result.state, 'state-xyz');
      expect(result.error, isNull);
    });

    test('resolves with an error when the provider reports one', () async {
      final server = await LoopbackRedirectServer.bind();
      addTearDown(server.close);

      final resultFuture = server.waitForCallback();
      await http.get(
        Uri.parse(server.redirectUri).replace(
          queryParameters: {'error': 'access_denied', 'state': 'state-xyz'},
        ),
      );

      final result = await resultFuture;
      expect(result.error, 'access_denied');
      expect(result.code, isNull);
    });

    test('close() stops the listener', () async {
      final server = await LoopbackRedirectServer.bind();
      final uri = Uri.parse(server.redirectUri);
      await server.close();

      await expectLater(http.get(uri), throwsA(anything));
    });
  });
}
