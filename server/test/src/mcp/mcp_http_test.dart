import 'package:server/src/mcp/mcp_http.dart';
import 'package:test/test.dart';

import '../otel/_span_test_helpers.dart';

void main() {
  group('mcp error responses annotate the current span', () {
    test('mcpMethodNotAllowed sets mcp.error', () async {
      final (_, data) = await spanFor(mcpMethodNotAllowed);
      expect(data.attributes['mcp.error'], 'method_not_allowed');
    });

    test('mcpForbidden sets mcp.error', () async {
      final (_, data) = await spanFor(mcpForbidden);
      expect(data.attributes['mcp.error'], 'forbidden');
    });

    test('mcpUnsupportedProtocolVersion sets mcp.error', () async {
      final (_, data) = await spanFor(mcpUnsupportedProtocolVersion);
      expect(data.attributes['mcp.error'], 'unsupported_protocol_version');
    });

    test('mcpPayloadTooLarge sets mcp.error', () async {
      final (_, data) = await spanFor(mcpPayloadTooLarge);
      expect(data.attributes['mcp.error'], 'payload_too_large');
    });
  });

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
