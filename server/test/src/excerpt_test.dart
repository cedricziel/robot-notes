import 'package:server/src/excerpt.dart';
import 'package:test/test.dart';

void main() {
  group('computeExcerpt', () {
    test('returns short content untouched, no ellipsis', () {
      expect(computeExcerpt('Just a short note.'), 'Just a short note.');
    });

    test('returns an empty string for empty content', () {
      expect(computeExcerpt(''), '');
    });

    test('collapses whitespace and newlines to a single line', () {
      expect(
        computeExcerpt('Line one\n\nLine   two\tindented'),
        'Line one Line two indented',
      );
    });

    test('strips heading markers', () {
      expect(
        computeExcerpt('# Weekend Trip\nPacking list below'),
        'Weekend Trip Packing list below',
      );
    });

    test('strips list markers at line start', () {
      expect(
        computeExcerpt(
          '- charcoal chimney\n- indirect heat\n* rest 10 min\n1. serve',
        ),
        'charcoal chimney indirect heat rest 10 min serve',
      );
    });

    test('strips emphasis markers', () {
      expect(
        computeExcerpt('This is **bold**, *italic*, and _also italic_ text'),
        'This is bold, italic, and also italic text',
      );
    });

    test('strips inline code spans, keeping their contents', () {
      expect(
        computeExcerpt('Run `flutter test` before committing'),
        'Run flutter test before committing',
      );
    });

    test('unwraps a [[Link|Alias]] to its alias', () {
      expect(
        computeExcerpt('See [[Weekend Trip|the trip note]] for details'),
        'See the trip note for details',
      );
    });

    test('unwraps a bare [[Link]] to its title', () {
      expect(
        computeExcerpt('See [[Weekend Trip]] for details'),
        'See Weekend Trip for details',
      );
    });

    test('drops inline #tag tokens', () {
      expect(computeExcerpt('Leaving Friday #travel #trip'), 'Leaving Friday');
    });

    test('does not treat a markdown heading as a tag token', () {
      expect(computeExcerpt('# Heading text'), 'Heading text');
    });

    test('preserves underscores inside inline code (no emphasis-stripping)',
        () {
      expect(
        computeExcerpt('Rename it to `snake_case` please'),
        'Rename it to snake_case please',
      );
    });

    test('preserves a hash inside inline code (not treated as a tag)', () {
      expect(
        computeExcerpt('Add `#pragma once` at the top'),
        'Add #pragma once at the top',
      );
    });

    test('preserves asterisks inside inline code', () {
      expect(
        computeExcerpt('The glob `*.md` matches every note'),
        'The glob *.md matches every note',
      );
    });

    test('preserves code contents inside a fenced block', () {
      expect(
        computeExcerpt('Before\n```\nsnake_case #tag *star*\n```\nAfter'),
        'Before snake_case #tag *star* After',
      );
    });

    test('truncates long content at a word boundary with an ellipsis', () {
      final content = 'word ' * 40;
      final excerpt = computeExcerpt(content, maxLength: 20);
      expect(excerpt.length, lessThanOrEqualTo(21));
      expect(excerpt.endsWith('…'), isTrue);
      expect(excerpt, isNot(contains('  ')));
    });

    test('does not add an ellipsis when stripped text is exactly the limit',
        () {
      const content = 'exactly';
      final excerpt = computeExcerpt(content, maxLength: 7);
      expect(excerpt, 'exactly');
    });

    test('hard-truncates when a single word exceeds the limit', () {
      final excerpt = computeExcerpt(
        'supercalifragilisticexpialidocious is a long word',
        maxLength: 10,
      );
      expect(excerpt.length, lessThanOrEqualTo(11));
      expect(excerpt.endsWith('…'), isTrue);
    });
  });
}
