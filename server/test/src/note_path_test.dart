import 'package:server/src/note_path.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeFilenameSegment', () {
    test('strips filesystem-illegal characters', () {
      expect(
        sanitizeFilenameSegment(r'a\b/c:d*e?f"g<h>i|j'),
        'abcdefghij',
      );
    });

    test('leaves an already-clean segment untouched', () {
      expect(sanitizeFilenameSegment('Meeting Notes'), 'Meeting Notes');
    });
  });

  group('normalizeToNfc', () {
    test('composes an NFD-decomposed character to NFC', () {
      // 'e' (U+0065) + combining acute accent (U+0301) -> composed 'é'
      // (single codepoint U+00E9).
      final decomposed = String.fromCharCodes([0x65, 0x0301]);
      final normalized = normalizeToNfc(decomposed);
      expect(normalized, String.fromCharCode(0x00e9));
      expect(normalized.length, 1);
    });

    test('is a no-op on already-composed input', () {
      const composed = 'café';
      expect(normalizeToNfc(composed), composed);
    });
  });

  group('sanitizedTitleForFilename', () {
    test('normalizes then sanitizes', () {
      final decomposedTitle = '${String.fromCharCodes([0x65, 0x0301])}'
          'clair: the pastry';
      expect(
        sanitizedTitleForFilename(decomposedTitle),
        '${String.fromCharCode(0x00e9)}clair the pastry',
      );
    });
  });

  group('sanitizedPathSegments', () {
    test('empty path yields no segments', () {
      expect(sanitizedPathSegments(''), isEmpty);
    });

    test('splits on / and sanitizes each segment', () {
      expect(
        sanitizedPathSegments('Projects/Alpha:Beta'),
        ['Projects', 'AlphaBeta'],
      );
    });

    test('rejects a .. segment (path traversal)', () {
      expect(
        () => sanitizedPathSegments('../etc'),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test('rejects a .. segment anywhere in the path, not just the start', () {
      expect(
        () => sanitizedPathSegments('Projects/../../etc'),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test('rejects a bare . segment', () {
      expect(
        () => sanitizedPathSegments('Projects/./Alpha'),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test(
      'rejects a segment that becomes .. only after stripping illegal '
      'characters',
      () {
        // ':' is stripped by sanitizeFilenameSegment, so '.:.' would
        // otherwise silently collapse to the traversal segment '..' if
        // the check ran before stripping instead of after.
        expect(
          () => sanitizedPathSegments('.:./etc'),
          throwsA(isA<InvalidPathException>()),
        );
      },
    );

    test('rejects a segment that becomes empty after stripping', () {
      // Every character in this segment is filesystem-illegal, so it
      // sanitizes down to the empty string, which would otherwise
      // silently produce a double slash in the resulting relative path.
      expect(
        () => sanitizedPathSegments('Projects/:*?/Alpha'),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test('does not reject a segment that merely contains dots', () {
      expect(
        sanitizedPathSegments('Projects/v1.2.3'),
        ['Projects', 'v1.2.3'],
      );
    });
  });

  group('collisionKey', () {
    test('is case-insensitive', () {
      expect(collisionKey('Ideas.md'), collisionKey('ideas.md'));
    });

    test('is normalization-insensitive', () {
      final nfd = '${String.fromCharCodes([0x65, 0x0301])}clair.md';
      final nfc = '${String.fromCharCode(0x00e9)}clair.md';
      expect(collisionKey(nfd), collisionKey(nfc));
    });

    test('distinguishes different names', () {
      expect(collisionKey('Ideas.md'), isNot(collisionKey('Ideas2.md')));
    });
  });
}
