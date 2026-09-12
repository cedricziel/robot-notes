import 'package:server/src/otel/otel_shutdown.dart';
import 'package:test/test.dart';

void main() {
  group('shutdownServer', () {
    test('runs every otel shutdown before closing the server', () async {
      final calls = <String>[];

      await shutdownServer(
        otelShutdowns: [
          () async => calls.add('logs'),
          () async => calls.add('traces'),
        ],
        closeServer: () async {
          calls.add('closeServer');
        },
      );

      expect(calls, containsAll(['logs', 'traces', 'closeServer']));
      expect(calls.last, 'closeServer');
    });

    test('closes the server even if an otel shutdown throws', () async {
      var otherShutdownCalled = false;
      var closeServerCalled = false;

      await expectLater(
        shutdownServer(
          otelShutdowns: [
            () async => throw StateError('export failed'),
            () async => otherShutdownCalled = true,
          ],
          closeServer: () async {
            closeServerCalled = true;
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(closeServerCalled, isTrue);
      expect(otherShutdownCalled, isTrue);
    });
  });
}
