import 'package:server/src/config.dart';
import 'package:test/test.dart';

void main() {
  group('Config.fromArgs', () {
    test('throws ConfigError when no key is configured', () {
      expect(
        () => Config.fromArgs(const [], env: const {}),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('--api-key'), contains('ROBOT_NOTES_API_KEY')),
          ),
        ),
      );
    });

    test('reads --api-key from CLI', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {},
      );
      expect(config.apiKey, 'rn_x');
    });

    test('falls back to ROBOT_NOTES_API_KEY env var', () {
      final config = Config.fromArgs(
        const [],
        env: const {'ROBOT_NOTES_API_KEY': 'rn_env'},
      );
      expect(config.apiKey, 'rn_env');
    });

    test('CLI argument wins over env var', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_arg'],
        env: const {'ROBOT_NOTES_API_KEY': 'rn_env'},
      );
      expect(config.apiKey, 'rn_arg');
    });

    test('default values when only --api-key is given', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {},
      );
      expect(config.dataDir, './data');
      expect(config.port, 8080);
      expect(config.lockTtlSeconds, 60);
    });

    test('--data-dir overrides default', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x', '--data-dir', '/srv/notes'],
        env: const {},
      );
      expect(config.dataDir, '/srv/notes');
    });

    test('--port parses to int', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x', '--port', '9090'],
        env: const {},
      );
      expect(config.port, 9090);
    });

    test('--lock-ttl-seconds parses to int', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x', '--lock-ttl-seconds', '30'],
        env: const {},
      );
      expect(config.lockTtlSeconds, 30);
    });

    test('env vars supply --data-dir / --port / --lock-ttl-seconds', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {
          'ROBOT_NOTES_DATA_DIR': '/var/notes',
          'ROBOT_NOTES_PORT': '7000',
          'ROBOT_NOTES_LOCK_TTL_SECONDS': '120',
        },
      );
      expect(config.dataDir, '/var/notes');
      expect(config.port, 7000);
      expect(config.lockTtlSeconds, 120);
    });

    test('CLI flags win over env vars for non-key settings', () {
      final config = Config.fromArgs(
        const [
          '--api-key',
          'rn_x',
          '--port',
          '9000',
          '--data-dir',
          '/cli',
          '--lock-ttl-seconds',
          '15',
        ],
        env: const {
          'ROBOT_NOTES_DATA_DIR': '/env',
          'ROBOT_NOTES_PORT': '7000',
          'ROBOT_NOTES_LOCK_TTL_SECONDS': '120',
        },
      );
      expect(config.dataDir, '/cli');
      expect(config.port, 9000);
      expect(config.lockTtlSeconds, 15);
    });

    test('rejects --port that is not an int', () {
      expect(
        () => Config.fromArgs(
          const ['--api-key', 'rn_x', '--port', 'abc'],
          env: const {},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('rejects --lock-ttl-seconds below 5', () {
      expect(
        () => Config.fromArgs(
          const ['--api-key', 'rn_x', '--lock-ttl-seconds', '2'],
          env: const {},
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message.toLowerCase(),
            'message',
            contains('lock'),
          ),
        ),
      );
    });

    test('webDir is null by default', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {},
      );
      expect(config.webDir, isNull);
    });

    test('--web-dir flag populates webDir', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x', '--web-dir', '/srv/web'],
        env: const {},
      );
      expect(config.webDir, '/srv/web');
    });

    test('ROBOT_NOTES_WEB_DIR env var populates webDir', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {'ROBOT_NOTES_WEB_DIR': '/env/web'},
      );
      expect(config.webDir, '/env/web');
    });

    test('--web-dir CLI flag wins over env var', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x', '--web-dir', '/cli/web'],
        env: const {'ROBOT_NOTES_WEB_DIR': '/env/web'},
      );
      expect(config.webDir, '/cli/web');
    });

    test('rejects empty --api-key', () {
      expect(
        () => Config.fromArgs(
          const ['--api-key', ''],
          env: const {},
        ),
        throwsA(isA<ConfigError>()),
      );
    });
  });

  group('Config.loadOrExit', () {
    test('returns config when valid', () {
      var exitCode = 0;
      final config = Config.loadOrExit(
        const ['--api-key', 'rn_x'],
        env: const {},
        exit: (int code) {
          exitCode = code;
          throw StateError('exit($code)');
        },
        printErr: (_) {},
      );
      expect(config.apiKey, 'rn_x');
      expect(exitCode, 0);
    });

    test('exits with non-zero code and prints error when invalid', () {
      var capturedExit = 0;
      final lines = <String>[];
      expect(
        () => Config.loadOrExit(
          const [],
          env: const {},
          exit: (int code) {
            capturedExit = code;
            throw StateError('exit($code)');
          },
          printErr: lines.add,
        ),
        throwsStateError,
      );
      expect(capturedExit, isNonZero);
      expect(lines.join('\n'), contains('--api-key'));
    });
  });
}
