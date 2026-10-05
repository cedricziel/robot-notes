import 'dart:async';
import 'dart:convert';

import 'package:app/src/config/config_store.dart';
import 'package:app/src/setup/setup_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

void main() {
  group('isSecureBaseUrl', () {
    test('accepts valid HTTPS and exact HTTP loopback hosts', () {
      for (final url in [
        'https://notes.example',
        ' HTTPS://notes.example:8443/ ',
        'http://localhost:8099',
        'http://127.0.0.1:8099',
        'http://[::1]:8099',
        ' HTTP://LOCALHOST:8099/ ',
      ]) {
        expect(isSecureBaseUrl(url), isTrue, reason: url);
      }
    });

    test(
      'rejects remote HTTP, deceptive hosts, userinfo, and malformed URLs',
      () {
        for (final url in [
          'http://notes.example',
          'http://localhost.example:8099',
          'http://127.0.0.1.example:8099',
          'http://127.0.0.2:8099',
          'http://127.1:8099',
          'http://0.0.0.0:8099',
          'http://192.168.1.2:8099',
          'http://localhost@notes.example:8099',
          'http://user:password@localhost:8099',
          'http://@localhost:8099',
          'https://user:password@notes.example',
          'https://',
          'https:///notes.example',
          'https://notes example',
          'https://notes.example:abc',
          'https://notes.example:65536',
          'https://[::1',
          r'https://notes.example\path',
          '//localhost:8099',
          'not a URL',
          '',
        ]) {
          expect(isSecureBaseUrl(url), isFalse, reason: url);
        }
      },
    );
  });

  group('SetupController.submit', () {
    late InMemoryConfigStore store;
    late Logger logger;
    late List<LogRecord> logs;
    late StreamSubscription<LogRecord> sub;

    setUp(() {
      store = InMemoryConfigStore();
      logger = Logger.detached('setup-test')..level = Level.ALL;
      logs = <LogRecord>[];
      sub = logger.onRecord.listen(logs.add);
    });

    tearDown(() async {
      await sub.cancel();
    });

    SetupController controllerWith(http.Client client) => SetupController(
      store: store,
      clientFactory: () => client,
      logger: logger,
    );

    for (final baseUrl in [
      'http://localhost:8099',
      'http://127.0.0.1:8099',
      'http://[::1]:8099',
    ]) {
      test('validates and persists local server $baseUrl', () async {
        final paths = <String>[];
        final controller = controllerWith(
          MockClient((request) async {
            expect(request.url.origin, baseUrl);
            paths.add(request.url.path);
            if (request.url.path == '/healthz') {
              expect(request.headers['Authorization'], isNull);
              return http.Response('{"status":"ok"}', 200);
            }
            expect(request.headers['Authorization'], 'Bearer local-key');
            expect(request.headers['X-Actor'], 'local-tester');
            return http.Response('{"items":[]}', 200);
          }),
        );
        addTearDown(controller.dispose);

        await controller.submit(
          baseUrl: '$baseUrl/',
          apiKey: 'local-key',
          actor: ' local-tester ',
        );

        expect(paths, ['/healthz', '/notes']);
        expect(controller.value, isA<SetupSuccess>());
        expect((await store.read())!.baseUrl, baseUrl);
      });
    }

    for (final baseUrl in [
      'http://localhost.example:8099',
      'http://user:password@localhost:8099',
      'https://user:password@notes.example',
      'https://',
      'https://notes.example:abc',
    ]) {
      test('rejects unsafe URL $baseUrl before creating a client', () async {
        final controller = SetupController(
          store: store,
          logger: logger,
          clientFactory: () {
            fail('A rejected URL must not create an HTTP client');
          },
        );
        addTearDown(controller.dispose);

        await controller.submit(baseUrl: baseUrl, apiKey: 'k', actor: 'local');

        expect(controller.value, isA<SetupFailed>());
        expect(
          (controller.value as SetupFailed).reason,
          SetupFailureReason.insecureUrl,
        );
        expect(await store.read(), isNull);
      });
    }

    test('401 surfaces unauthorized state and does not persist', () async {
      // Two calls: first /healthz (200), then /notes?limit=1 (401).
      var call = 0;
      final mock = MockClient((request) async {
        call += 1;
        if (call == 1) {
          expect(request.url.path, '/healthz');
          return http.Response('{"status":"ok"}', 200);
        }
        expect(request.url.path, '/notes');
        return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
      });

      final controller = controllerWith(mock);

      await controller.submit(
        baseUrl: 'https://notes.example',
        apiKey: 'wrong-key',
        actor: 'cedric',
      );

      final state = controller.value;
      expect(state, isA<SetupFailed>());
      expect((state as SetupFailed).reason, SetupFailureReason.unauthorized);
      expect(state.message, contains('API key'));
      expect(await store.read(), isNull);
    });

    test('http:// base url is rejected before any request is sent', () async {
      final mock = MockClient((request) async {
        fail('no request should be sent for a plain-http base url');
      });

      final controller = controllerWith(mock);

      await controller.submit(
        baseUrl: 'http://notes.example',
        apiKey: 'k',
        actor: 'cedric',
      );

      final state = controller.value;
      expect(state, isA<SetupFailed>());
      expect((state as SetupFailed).reason, SetupFailureReason.insecureUrl);
      expect(state.message, contains('https://'));
      expect(await store.read(), isNull);
    });

    test(
      'unreachable server surfaces network failure and does not persist',
      () async {
        final mock = MockClient((request) async {
          throw http.ClientException('Connection refused', request.url);
        });

        final controller = controllerWith(mock);

        await controller.submit(
          baseUrl: 'https://offline.example',
          apiKey: 'k',
          actor: 'cedric',
        );

        final state = controller.value;
        expect(state, isA<SetupFailed>());
        expect((state as SetupFailed).reason, SetupFailureReason.network);
        expect(await store.read(), isNull);
      },
    );

    test(
      'successful validation persists normalized config and reports success',
      () async {
        final mock = MockClient((request) async {
          if (request.url.path == '/healthz') {
            return http.Response('{"status":"ok"}', 200);
          }
          expect(request.url.path, '/notes');
          expect(request.headers['Authorization'], 'Bearer good-key');
          expect(request.headers['X-Actor'], 'cedric');
          return http.Response(
            jsonEncode(<String, Object?>{'items': <Object?>[], 'next': null}),
            200,
          );
        });

        final controller = controllerWith(mock);

        await controller.submit(
          baseUrl: 'https://notes.example/',
          apiKey: 'good-key',
          actor: '  cedric  ',
        );

        final state = controller.value;
        expect(state, isA<SetupSuccess>());
        final stored = await store.read();
        expect(stored, isNotNull);
        // Normalized: trailing slash stripped, actor trimmed.
        expect(stored!.baseUrl, 'https://notes.example');
        expect(stored.actor, 'cedric');
        expect(stored.apiKey, 'good-key');
      },
    );

    test('api key never appears in any log record', () async {
      // Run all three branches (success, 401, network) so every log code path
      // is exercised — and assert the key never lands in logger output.
      const secret = 'never-log-this-key';

      final clientOk = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response(
          jsonEncode(<String, Object?>{'items': <Object?>[], 'next': null}),
          200,
        );
      });
      final client401 = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
      });
      final clientDown = MockClient((request) async {
        throw http.ClientException('Connection refused', request.url);
      });

      final clients = <http.Client>[clientOk, client401, clientDown];
      for (final client in clients) {
        final controller = controllerWith(client);
        await controller.submit(
          baseUrl: 'https://notes.example',
          apiKey: secret,
          actor: 'cedric',
        );
      }

      final blob = logs
          .map((r) => '${r.message} ${r.error ?? ''} ${r.stackTrace ?? ''}')
          .join('\n');
      expect(
        blob.contains(secret),
        isFalse,
        reason: 'apiKey leaked into logs:\n$blob',
      );
    });
  });
}
