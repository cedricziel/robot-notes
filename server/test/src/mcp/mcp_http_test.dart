import 'package:server/src/mcp/mcp_http.dart';
import 'package:test/test.dart';

void main() {
  group('isAllowedMcpOrigin', () {
    test('accepts an http loopback origin regardless of publicUrl', () {
      expect(
        isAllowedMcpOrigin('http://localhost:53421', null),
        isTrue,
      );
      expect(
        isAllowedMcpOrigin('http://127.0.0.1:9', 'https://notes.example.com'),
        isTrue,
      );
      expect(
        isAllowedMcpOrigin('http://[::1]:1', 'https://notes.example.com'),
        isTrue,
      );
    });

    test('accepts the exact configured publicUrl origin', () {
      expect(
        isAllowedMcpOrigin(
          'https://notes.example.com',
          'https://notes.example.com',
        ),
        isTrue,
      );
    });

    test('rejects a foreign origin when publicUrl is configured', () {
      expect(
        isAllowedMcpOrigin('https://evil.example', 'https://notes.example.com'),
        isFalse,
      );
    });

    test(
      'rejects every non-loopback origin when publicUrl is unset — a '
      'Host-derived origin would let a DNS-rebinding attacker pick it',
      () {
        expect(isAllowedMcpOrigin('https://notes.example.com', null), isFalse);
        expect(isAllowedMcpOrigin('http://attacker.example', null), isFalse);
      },
    );

    test('rejects an unparsable origin', () {
      expect(
        isAllowedMcpOrigin('not a uri', 'https://notes.example.com'),
        isFalse,
      );
    });

    test(
      'rejects an https loopback origin (only http loopback is trusted)',
      () {
        expect(isAllowedMcpOrigin('https://localhost', null), isFalse);
      },
    );
  });
}
