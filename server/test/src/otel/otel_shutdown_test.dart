import 'package:flutter_otel_api/flutter_otel_api.dart';
import 'package:server/src/otel/otel_shutdown.dart';
import 'package:test/test.dart';

class _FakeLoggerProvider implements LoggerProvider {
  bool shutdownCalled = false;

  @override
  Logger getLogger({
    String name = defaultInstrumentationScopeName,
    String? version,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    shutdownCalled = true;
  }
}

void main() {
  group('shutdownServer', () {
    test('shuts down the otel provider before closing the server', () async {
      final provider = _FakeLoggerProvider();
      final calls = <String>[];

      await shutdownServer(
        otelLoggerProvider: provider,
        closeServer: () async {
          calls.add('closeServer');
        },
      );

      expect(provider.shutdownCalled, isTrue);
      expect(calls, ['closeServer']);
    });

    test('closes the server even if otel shutdown throws', () async {
      final provider = _ThrowingLoggerProvider();
      var closeServerCalled = false;

      await expectLater(
        shutdownServer(
          otelLoggerProvider: provider,
          closeServer: () async {
            closeServerCalled = true;
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(closeServerCalled, isTrue);
    });
  });
}

class _ThrowingLoggerProvider implements LoggerProvider {
  @override
  Logger getLogger({
    String name = defaultInstrumentationScopeName,
    String? version,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    throw StateError('export failed');
  }
}
