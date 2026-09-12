import 'package:server/src/tags.dart';
import 'package:test/test.dart';

void main() {
  group('computeTags', () {
    test('merges frontmatter tags and inline #tag tokens', () {
      final tags = computeTags(
        extra: {
          'tags': ['planning'],
        },
        content: 'next up: #urgent',
      );
      expect(tags, {'planning', 'urgent'});
    });

    test('recognizes a nested tag', () {
      final tags = computeTags(
        extra: const {},
        content: 'working on #work/robot-notes today',
      );
      expect(tags, {'work/robot-notes'});
    });

    test('a duplicate tag across sources counts once', () {
      final tags = computeTags(
        extra: {
          'tags': ['urgent'],
        },
        content: 'also #urgent here',
      );
      expect(tags, {'urgent'});
      expect(tags, hasLength(1));
    });

    test('matching is case-insensitive; first-seen casing is displayed', () {
      final tags = computeTags(
        extra: {
          'tags': ['Urgent'],
        },
        content: 'see #urgent for details',
      );
      expect(tags, {'Urgent'});
    });

    test('inline casing wins when frontmatter has no matching tag', () {
      final tags = computeTags(
        extra: const {},
        content: 'first #Urgent then later #urgent again',
      );
      expect(tags, {'Urgent'});
    });

    test('no tags anywhere yields an empty set', () {
      final tags = computeTags(extra: const {}, content: 'nothing here');
      expect(tags, isEmpty);
    });

    test('a non-list frontmatter tags value is ignored, not thrown', () {
      final tags = computeTags(
        extra: {'tags': 'not-a-list'},
        content: '#ok',
      );
      expect(tags, {'ok'});
    });

    test('a hash not followed by a tag character is not a tag', () {
      final tags = computeTags(extra: const {}, content: '# Heading\ntext');
      expect(tags, isEmpty);
    });
  });

  group('aggregateTagCounts', () {
    test('sorts by descending count', () {
      final counts = aggregateTagCounts([
        {'urgent'},
        {'urgent'},
        {'urgent', 'later'},
      ]);
      expect(counts.map((c) => (c.tag, c.count)), [
        ('urgent', 3),
        ('later', 1),
      ]);
    });

    test('case-insensitive across sets, first-seen casing wins', () {
      final counts = aggregateTagCounts([
        {'Urgent'},
        {'urgent'},
      ]);
      expect(counts, hasLength(1));
      expect(counts.single.tag, 'Urgent');
      expect(counts.single.count, 2);
    });
  });
}
