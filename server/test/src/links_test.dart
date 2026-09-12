import 'package:server/src/links.dart';
import 'package:test/test.dart';

void main() {
  group('parseLinks', () {
    test('extracts a simple [[Title]] link', () {
      final links = parseLinks('See [[Project Alpha]] for details');
      expect(links, hasLength(1));
      expect(links.single.targetTitle, 'Project Alpha');
      expect(links.single.alias, isNull);
    });

    test('extracts a [[Title|Alias]] link with alias', () {
      final links = parseLinks('See [[Project Alpha|the plan]]');
      expect(links, hasLength(1));
      expect(links.single.targetTitle, 'Project Alpha');
      expect(links.single.alias, 'the plan');
    });

    test('treats a heading anchor as part of the literal title', () {
      final links = parseLinks('[[Project Alpha#Milestones]]');
      expect(links, hasLength(1));
      expect(links.single.targetTitle, 'Project Alpha#Milestones');
      expect(links.single.alias, isNull);
    });

    test('returns no links for content with none', () {
      expect(parseLinks('just plain text, no brackets here'), isEmpty);
    });

    test('extracts multiple links in document order', () {
      final links = parseLinks('[[First]] then [[Second|two]] then [[Third]]');
      expect(links.map((l) => l.targetTitle), ['First', 'Second', 'Third']);
      expect(links.map((l) => l.alias), [null, 'two', null]);
    });

    test('leaves the raw content untouched (parsing is read-only)', () {
      const content = 'See [[Project Alpha|the plan]] for details';
      parseLinks(content);
      expect(content, 'See [[Project Alpha|the plan]] for details');
    });

    test('position info exactly spans the [[...]] occurrence', () {
      const content = 'prefix [[Project Alpha|the plan]] suffix';
      final link = parseLinks(content).single;
      expect(
        content.substring(link.start, link.end),
        '[[Project Alpha|the plan]]',
      );
    });

    test('ignores an unclosed [[ with no matching ]]', () {
      expect(parseLinks('this has [[ no closing brackets'), isEmpty);
    });
  });

  group('rewriteLinks', () {
    test('rewrites a bare link to the old title, preserving no alias', () {
      final result = rewriteLinks(
        'See [[Old Name]] for details',
        oldTitle: 'Old Name',
        newTitle: 'New Name',
      );
      expect(result, 'See [[New Name]] for details');
    });

    test('rewrites an aliased link, preserving the alias', () {
      final result = rewriteLinks(
        'See [[Old Name|the plan]] for details',
        oldTitle: 'Old Name',
        newTitle: 'New Name',
      );
      expect(result, 'See [[New Name|the plan]] for details');
    });

    test('rewrites every matching occurrence in one document', () {
      final result = rewriteLinks(
        '[[Old Name]] and again [[Old Name|alt]]',
        oldTitle: 'Old Name',
        newTitle: 'New Name',
      );
      expect(result, '[[New Name]] and again [[New Name|alt]]');
    });

    test('does not touch links targeting a different title', () {
      final result = rewriteLinks(
        '[[Old Name]] and [[Other]]',
        oldTitle: 'Old Name',
        newTitle: 'New Name',
      );
      expect(result, '[[New Name]] and [[Other]]');
    });

    test('does not touch an incidental plain-text mention', () {
      const content = 'Old Name was a great project, unlike [[Old Name]]';
      final result = rewriteLinks(
        content,
        oldTitle: 'Old Name',
        newTitle: 'New Name',
      );
      expect(
        result,
        'Old Name was a great project, unlike [[New Name]]',
      );
    });

    test('is a no-op when there is nothing to rewrite', () {
      const content = 'nothing to see here';
      expect(
        rewriteLinks(content, oldTitle: 'Old Name', newTitle: 'New Name'),
        content,
      );
    });
  });
}
