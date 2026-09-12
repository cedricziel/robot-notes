import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/config.dart';
import 'package:server/src/public_url.dart';
import 'package:test/test.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required Config config,
  Map<String, String> headers = const {},
  Uri? uri,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.uri).thenReturn(uri ?? Uri.parse('http://localhost/mcp'));
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<Config>()).thenReturn(config);
  return ctx;
}

Config _config({String? publicUrl}) => Config(
      apiKey: 'rn_test',
      dataDir: '/tmp',
      port: 8080,
      lockTtlSeconds: 60,
      publicUrl: publicUrl,
    );

void main() {
  group('publicBaseUrl', () {
    test('returns the configured public URL when set', () {
      final ctx = _ctx(
        config: _config(publicUrl: 'https://notes.example.com'),
        headers: {'host': '10.0.0.5:8080'},
      );
      expect(publicBaseUrl(ctx), 'https://notes.example.com');
    });

    test('falls back to X-Forwarded-Proto + Host when unconfigured', () {
      final ctx = _ctx(
        config: _config(),
        headers: {
          'host': 'notes.example.com',
          'x-forwarded-proto': 'https',
        },
      );
      expect(publicBaseUrl(ctx), 'https://notes.example.com');
    });

    test('falls back to the request scheme + Host with no forwarded header',
        () {
      final ctx = _ctx(
        config: _config(),
        headers: {'host': 'notes.example.com:9090'},
        uri: Uri.parse('http://localhost:9090/mcp'),
      );
      expect(publicBaseUrl(ctx), 'http://notes.example.com:9090');
    });

    test('defaults scheme to http and host to localhost', () {
      final ctx = _ctx(
        config: _config(),
        uri: Uri.parse('http://localhost/mcp'),
      );
      expect(publicBaseUrl(ctx), 'http://localhost');
    });

    test('never ends with a trailing slash', () {
      final ctx = _ctx(
        config: _config(publicUrl: 'https://notes.example.com'),
      );
      expect(publicBaseUrl(ctx), isNot(endsWith('/')));
    });

    test('uses only the first value of a comma-separated forwarded proto', () {
      final ctx = _ctx(
        config: _config(),
        headers: {
          'host': 'notes.example.com',
          'x-forwarded-proto': 'https,http',
        },
      );
      expect(publicBaseUrl(ctx), 'https://notes.example.com');
    });

    test('rejects a forwarded proto that is not http or https', () {
      final ctx = _ctx(
        config: _config(),
        headers: {
          'host': 'notes.example.com',
          'x-forwarded-proto': 'https://evil.example/a?x=',
        },
        uri: Uri.parse('http://localhost/mcp'),
      );
      expect(publicBaseUrl(ctx), 'http://notes.example.com');
    });

    test('accepts an upper-case or padded forwarded proto', () {
      final ctx = _ctx(
        config: _config(),
        headers: {
          'host': 'notes.example.com',
          'x-forwarded-proto': ' HTTPS ',
        },
      );
      expect(publicBaseUrl(ctx), 'https://notes.example.com');
    });
  });

  group('mcpResourceUrl', () {
    test('appends /mcp to the base', () {
      expect(
        mcpResourceUrl('https://notes.example.com'),
        'https://notes.example.com/mcp',
      );
    });
  });

  group('publicUrlStartupWarning', () {
    test('names ROBOT_NOTES_PUBLIC_URL when the public URL is unset', () {
      final warning = publicUrlStartupWarning(_config());
      expect(warning, isNotNull);
      expect(warning, contains('ROBOT_NOTES_PUBLIC_URL'));
      expect(warning, contains('--public-url'));
    });

    test('is null when the public URL is configured', () {
      final config = _config(publicUrl: 'https://notes.example.com');
      expect(publicUrlStartupWarning(config), isNull);
    });
  });
}
