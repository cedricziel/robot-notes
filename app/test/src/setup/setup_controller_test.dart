import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/src/config/config_store.dart';
import 'package:app/src/setup/setup_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

void main() {
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
        return http.Response(
          jsonEncode({'error': 'unauthorized'}),
          401,
        );
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

    test(
      'unreachable server surfaces network failure and does not persist',
      () async {
        final mock = MockClient((request) async {
          throw const SocketException('Connection refused');
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

    test('successful validation persists normalized config and reports success',
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
    });

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
        throw const SocketException('Connection refused');
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
