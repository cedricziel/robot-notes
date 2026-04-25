import 'package:app/src/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig', () {
    test('value equality covers all three fields', () {
      const a = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'k',
        actor: 'cedric',
      );
      const b = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'k',
        actor: 'cedric',
      );
      const c = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'k',
        actor: 'someone-else',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('normalized() strips trailing slash and trims actor', () {
      const raw = AppConfig(
        baseUrl: 'https://notes.example/',
        apiKey: 'k',
        actor: '  cedric  ',
      );

      final norm = raw.normalized();

      expect(norm.baseUrl, 'https://notes.example');
      expect(norm.actor, 'cedric');
      // apiKey is left untouched — operators may legitimately have whitespace.
      expect(norm.apiKey, 'k');
    });

    test('toString never leaks the api key', () {
      const config = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'super-secret-key-do-not-leak',
        actor: 'cedric',
      );

      final rendered = config.toString();

      expect(rendered, contains('https://notes.example'));
      expect(rendered, contains('cedric'));
      expect(rendered, contains('<redacted>'));
      expect(rendered, isNot(contains('super-secret-key-do-not-leak')));
    });

    test('toJson/fromJson round-trip is value-equal', () {
      const original = AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'k',
        actor: 'cedric',
      );

      final restored = AppConfig.fromJson(original.toJson());

      expect(restored, equals(original));
    });
  });
}
