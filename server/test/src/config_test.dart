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

    test('publicUrl is null when unset', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {},
      );
      expect(config.publicUrl, isNull);
    });

    test('--public-url populates publicUrl without trailing slash', () {
      final config = Config.fromArgs(
        const [
          '--api-key',
          'rn_x',
          '--public-url',
          'https://notes.example.com',
        ],
        env: const {},
      );
      expect(config.publicUrl, 'https://notes.example.com');
    });

    test('--public-url strips a bare trailing slash path', () {
      final config = Config.fromArgs(
        const [
          '--api-key',
          'rn_x',
          '--public-url',
          'https://notes.example.com/',
        ],
        env: const {},
      );
      expect(config.publicUrl, 'https://notes.example.com');
    });

    test('ROBOT_NOTES_PUBLIC_URL env var populates publicUrl', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {'ROBOT_NOTES_PUBLIC_URL': 'http://10.0.0.5:8080'},
      );
      expect(config.publicUrl, 'http://10.0.0.5:8080');
    });

    test('--public-url CLI flag wins over env var', () {
      final config = Config.fromArgs(
        const [
          '--api-key',
          'rn_x',
          '--public-url',
          'https://cli.example.com',
        ],
        env: const {'ROBOT_NOTES_PUBLIC_URL': 'https://env.example.com'},
      );
      expect(config.publicUrl, 'https://cli.example.com');
    });

    test('rejects --public-url with a path', () {
      expect(
        () => Config.fromArgs(
          const ['--api-key', 'rn_x', '--public-url', 'notes.example.com/app'],
          env: const {},
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('--public-url'), contains('ROBOT_NOTES_PUBLIC_URL')),
          ),
        ),
      );
    });

    test('rejects --public-url with a query string', () {
      expect(
        () => Config.fromArgs(
          const [
            '--api-key',
            'rn_x',
            '--public-url',
            'https://notes.example.com?x=1',
          ],
          env: const {},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('rejects --public-url with a fragment', () {
      expect(
        () => Config.fromArgs(
          const [
            '--api-key',
            'rn_x',
            '--public-url',
            'https://notes.example.com#frag',
          ],
          env: const {},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('rejects --public-url missing a scheme', () {
      expect(
        () => Config.fromArgs(
          const ['--api-key', 'rn_x', '--public-url', 'notes.example.com'],
          env: const {},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('rejects --public-url with a non-http(s) scheme', () {
      expect(
        () => Config.fromArgs(
          const [
            '--api-key',
            'rn_x',
            '--public-url',
            'ftp://notes.example.com',
          ],
          env: const {},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('rejects --public-url with userinfo', () {
      expect(
        () => Config.fromArgs(
          const [
            '--api-key',
            'rn_x',
            '--public-url',
            'https://user:pw@notes.example.com',
          ],
          env: const {},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('otlpEndpoint is null and otlpHeaders is empty by default', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {},
      );
      expect(config.otlpEndpoint, isNull);
      expect(config.otlpHeaders, isEmpty);
    });

    test('--otel-endpoint populates otlpEndpoint', () {
      final config = Config.fromArgs(
        const [
          '--api-key',
          'rn_x',
          '--otel-endpoint',
          'https://otel.example.com',
        ],
        env: const {},
      );
      expect(config.otlpEndpoint, Uri.parse('https://otel.example.com'));
    });

    test('ROBOT_NOTES_OTEL_ENDPOINT env var populates otlpEndpoint', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {'ROBOT_NOTES_OTEL_ENDPOINT': 'https://env.example.com'},
      );
      expect(config.otlpEndpoint, Uri.parse('https://env.example.com'));
    });

    test('--otel-endpoint CLI flag wins over env var', () {
      final config = Config.fromArgs(
        const [
          '--api-key',
          'rn_x',
          '--otel-endpoint',
          'https://cli.example.com',
        ],
        env: const {'ROBOT_NOTES_OTEL_ENDPOINT': 'https://env.example.com'},
      );
      expect(config.otlpEndpoint, Uri.parse('https://cli.example.com'));
    });

    test('otelEnvironmentName defaults to "production"', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {},
      );
      expect(config.otelEnvironmentName, 'production');
    });

    test('--otel-environment-name overrides the default', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x', '--otel-environment-name', 'staging'],
        env: const {},
      );
      expect(config.otelEnvironmentName, 'staging');
    });

    test(
      'ROBOT_NOTES_OTEL_ENVIRONMENT_NAME env var overrides the default',
      () {
        final config = Config.fromArgs(
          const ['--api-key', 'rn_x'],
          env: const {'ROBOT_NOTES_OTEL_ENVIRONMENT_NAME': 'staging'},
        );
        expect(config.otelEnvironmentName, 'staging');
      },
    );

    test('--otel-environment-name CLI flag wins over env var', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x', '--otel-environment-name', 'cli-env'],
        env: const {'ROBOT_NOTES_OTEL_ENVIRONMENT_NAME': 'env-env'},
      );
      expect(config.otelEnvironmentName, 'cli-env');
    });

    test('rejects --otel-endpoint with a non-http(s) scheme', () {
      expect(
        () => Config.fromArgs(
          const [
            '--api-key',
            'rn_x',
            '--otel-endpoint',
            'ftp://otel.example.com',
          ],
          env: const {},
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('--otel-endpoint'),
              contains('ROBOT_NOTES_OTEL_ENDPOINT'),
            ),
          ),
        ),
      );
    });

    test('rejects --otel-endpoint missing a host', () {
      expect(
        () => Config.fromArgs(
          const ['--api-key', 'rn_x', '--otel-endpoint', 'https://'],
          env: const {},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('--otel-headers parses comma-separated key=value pairs', () {
      final config = Config.fromArgs(
        const [
          '--api-key',
          'rn_x',
          '--otel-headers',
          'Authorization=Bearer abc,X-Tenant=homelab',
        ],
        env: const {},
      );
      expect(config.otlpHeaders, {
        'Authorization': 'Bearer abc',
        'X-Tenant': 'homelab',
      });
    });

    test('ROBOT_NOTES_OTEL_HEADERS env var populates otlpHeaders', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x'],
        env: const {'ROBOT_NOTES_OTEL_HEADERS': 'X-Api-Key=secret'},
      );
      expect(config.otlpHeaders, {'X-Api-Key': 'secret'});
    });

    test('--otel-headers CLI flag wins over env var', () {
      final config = Config.fromArgs(
        const ['--api-key', 'rn_x', '--otel-headers', 'X-Api-Key=cli'],
        env: const {'ROBOT_NOTES_OTEL_HEADERS': 'X-Api-Key=env'},
      );
      expect(config.otlpHeaders, {'X-Api-Key': 'cli'});
    });

    test('rejects --otel-headers entry missing "="', () {
      expect(
        () => Config.fromArgs(
          const ['--api-key', 'rn_x', '--otel-headers', 'not-a-pair'],
          env: const {},
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('--otel-headers'),
          ),
        ),
      );
    });

    group('OIDC login', () {
      test('oidc is null when none of the three settings are set', () {
        final config = Config.fromArgs(
          const ['--api-key', 'rn_x'],
          env: const {},
        );
        expect(config.oidc, isNull);
      });

      test('reads all three from CLI flags', () {
        final config = Config.fromArgs(
          const [
            '--api-key',
            'rn_x',
            '--oidc-issuer',
            'https://idp.example.com',
            '--oidc-client-id',
            'robot-notes',
            '--oidc-client-secret',
            'shh',
          ],
          env: const {},
        );
        expect(config.oidc, isNotNull);
        expect(config.oidc!.issuer, 'https://idp.example.com');
        expect(config.oidc!.clientId, 'robot-notes');
        expect(config.oidc!.clientSecret, 'shh');
      });

      test('falls back to ROBOT_NOTES_OIDC_* env vars', () {
        final config = Config.fromArgs(
          const ['--api-key', 'rn_x'],
          env: const {
            'ROBOT_NOTES_OIDC_ISSUER': 'https://idp.example.com',
            'ROBOT_NOTES_OIDC_CLIENT_ID': 'robot-notes',
            'ROBOT_NOTES_OIDC_CLIENT_SECRET': 'shh',
          },
        );
        expect(config.oidc, isNotNull);
        expect(config.oidc!.issuer, 'https://idp.example.com');
      });

      test('CLI flag wins over env var per setting', () {
        final config = Config.fromArgs(
          const ['--api-key', 'rn_x', '--oidc-issuer', 'https://cli.example'],
          env: const {
            'ROBOT_NOTES_OIDC_ISSUER': 'https://env.example',
            'ROBOT_NOTES_OIDC_CLIENT_ID': 'robot-notes',
            'ROBOT_NOTES_OIDC_CLIENT_SECRET': 'shh',
          },
        );
        expect(config.oidc!.issuer, 'https://cli.example');
      });

      test('throws naming the missing settings when only one is set', () {
        expect(
          () => Config.fromArgs(
            const [
              '--api-key',
              'rn_x',
              '--oidc-issuer',
              'https://idp.example.com',
            ],
            env: const {},
          ),
          throwsA(
            isA<ConfigError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('--oidc-client-id'),
                contains('--oidc-client-secret'),
              ),
            ),
          ),
        );
      });

      test('throws naming the missing setting when two of three are set', () {
        expect(
          () => Config.fromArgs(
            const [
              '--api-key',
              'rn_x',
              '--oidc-issuer',
              'https://idp.example.com',
              '--oidc-client-id',
              'robot-notes',
            ],
            env: const {},
          ),
          throwsA(
            isA<ConfigError>().having(
              (e) => e.message,
              'message',
              contains('--oidc-client-secret'),
            ),
          ),
        );
      });
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
