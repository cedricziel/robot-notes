import 'dart:convert';

import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tool_results.dart';
import 'package:test/test.dart';

void main() {
  group('toolOk', () {
    test('wraps the payload as JSON text plus structuredContent', () {
      final result = toolOk({'id': 'abc', 'version': 1});

      expect(result['isError'], isNull);
      expect(result['structuredContent'], {'id': 'abc', 'version': 1});

      final content = result['content']! as List<Object?>;
      expect(content, hasLength(1));
      final item = content.single! as Map<String, Object?>;
      expect(item['type'], 'text');
      expect(jsonDecode(item['text']! as String), {'id': 'abc', 'version': 1});
    });
  });

  group('toolFail', () {
    test('sets isError and a text item beginning with the code', () {
      final result = toolFail('not_found', message: 'no such note');

      expect(result['isError'], isTrue);
      final content = result['content']! as List<Object?>;
      final item = content.single! as Map<String, Object?>;
      expect(item['text'], startsWith('not_found:'));

      final structured = result['structuredContent']! as Map<String, Object?>;
      expect(structured['error'], 'not_found');
      expect(structured['message'], 'no such note');
    });

    test('merges details into structuredContent', () {
      final result = toolFail('locked', details: {'holder': 'alice'});

      final structured = result['structuredContent']! as Map<String, Object?>;
      expect(structured['error'], 'locked');
      expect(structured['holder'], 'alice');
    });

    test('falls back to the code when no message is supplied', () {
      final result = toolFail('validation_failed');

      final content = result['content']! as List<Object?>;
      final item = content.single! as Map<String, Object?>;
      expect(item['text'], 'validation_failed: validation_failed');
    });
  });

  group('McpPrincipal', () {
    test('staticKey grants both scopes', () {
      const principal = McpPrincipal.staticKey('research-bot');

      expect(principal.actor, 'research-bot');
      expect(principal.isStaticKey, isTrue);
      expect(principal.canRead, isTrue);
      expect(principal.canWrite, isTrue);
      expect(principal.scopes, {kScopeNotesRead, kScopeNotesWrite});
    });

    test('a read-only OAuth grant cannot write', () {
      const principal = McpPrincipal(
        actor: 'desk-assistant',
        scopes: {kScopeNotesRead},
        isStaticKey: false,
      );

      expect(principal.canRead, isTrue);
      expect(principal.canWrite, isFalse);
    });

    test('a write-only OAuth grant cannot read', () {
      const principal = McpPrincipal(
        actor: 'desk-assistant',
        scopes: {kScopeNotesWrite},
        isStaticKey: false,
      );

      expect(principal.canRead, isFalse);
      expect(principal.canWrite, isTrue);
    });
  });
}
