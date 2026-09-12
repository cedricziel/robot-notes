import 'dart:async';

import 'package:app/src/notes/link_autocomplete.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectLinkTrigger', () {
    test('returns null when there is no "[[" before the cursor', () {
      expect(detectLinkTrigger('hello world', 5), isNull);
    });

    test('detects an open trigger right after "[["', () {
      final trigger = detectLinkTrigger('see [[', 6);
      expect(trigger, isNotNull);
      expect(trigger!.start, 4);
      expect(trigger.end, 6);
      expect(trigger.query, '');
      expect(trigger.alias, isNull);
    });

    test('captures partial title text as the query', () {
      final trigger = detectLinkTrigger('see [[Proj', 10);
      expect(trigger, isNotNull);
      expect(trigger!.query, 'Proj');
      expect(trigger.alias, isNull);
    });

    test('splits query and alias on a pipe', () {
      final trigger = detectLinkTrigger('see [[Proj|My Alias', 19);
      expect(trigger, isNotNull);
      expect(trigger!.query, 'Proj');
      expect(trigger.alias, 'My Alias');
    });

    test('returns null once the link is already closed', () {
      expect(detectLinkTrigger('see [[Done]] more', 12), isNull);
    });

    test('uses the nearest unclosed "[[" when there are several', () {
      const text = '[[A]] and [[B';
      final trigger = detectLinkTrigger(text, text.length);
      expect(trigger, isNotNull);
      expect(trigger!.start, 10);
      expect(trigger.query, 'B');
    });
  });

  group('insertLink', () {
    test('inserts a plain [[Title]] at the trigger span', () {
      const text = 'see [[Proj';
      final trigger = detectLinkTrigger(text, text.length)!;

      final result = insertLink(text, trigger, 'Project Alpha');

      expect(result.text, 'see [[Project Alpha]]');
      expect(result.cursor, 'see [[Project Alpha]]'.length);
    });

    test('preserves a typed alias as [[Title|Alias]]', () {
      const text = 'see [[Proj|Alpha doc';
      final trigger = detectLinkTrigger(text, text.length)!;

      final result = insertLink(text, trigger, 'Project Alpha');

      expect(result.text, 'see [[Project Alpha|Alpha doc]]');
    });

    test('replaces only the trigger span, keeping surrounding text', () {
      const text = 'before [[Proj after';
      final cursor = text.indexOf('Proj') + 'Proj'.length;
      final trigger = detectLinkTrigger(text, cursor)!;

      final result = insertLink(text, trigger, 'Project Alpha');

      expect(result.text, 'before [[Project Alpha]] after');
    });
  });

  group('LinkAutocompleteController', () {
    test('onChanged opens and fetches matching titles for a trigger', () async {
      final queries = <String>[];
      final ctrl = LinkAutocompleteController(
        search: (q) async {
          queries.add(q);
          return ['Project Alpha', 'Project Beta'];
        },
        scheduler: (_) => Future<void>.value(),
      );
      addTearDown(ctrl.dispose);

      ctrl.onChanged('see [[Proj', 10);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(queries, ['Proj']);
      expect(ctrl.value.isOpen, isTrue);
      expect(ctrl.value.suggestions, ['Project Alpha', 'Project Beta']);
    });

    test('onChanged closes when there is no open trigger', () async {
      final ctrl = LinkAutocompleteController(
        search: (q) async => ['Project Alpha'],
        scheduler: (_) => Future<void>.value(),
      );
      addTearDown(ctrl.dispose);

      ctrl.onChanged('see [[Proj', 10);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.value.isOpen, isTrue);

      ctrl.onChanged('see [[Proj]] done', 17);
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.isOpen, isFalse);
      expect(ctrl.value.suggestions, isEmpty);
    });

    test('close() clears state directly', () async {
      final ctrl = LinkAutocompleteController(
        search: (q) async => ['Project Alpha'],
        scheduler: (_) => Future<void>.value(),
      );
      addTearDown(ctrl.dispose);

      ctrl.onChanged('see [[Proj', 10);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.value.isOpen, isTrue);

      ctrl.close();

      expect(ctrl.value.isOpen, isFalse);
    });

    test('a later keystroke supersedes an in-flight search', () async {
      final gate = Completer<void>();
      var calls = 0;
      final ctrl = LinkAutocompleteController(
        search: (q) async {
          calls += 1;
          if (q == 'P') {
            await gate.future;
            return ['stale'];
          }
          return ['Project Alpha'];
        },
        scheduler: (_) => Future<void>.value(),
      );
      addTearDown(ctrl.dispose);

      ctrl.onChanged('[[P', 3);
      await Future<void>.delayed(Duration.zero);
      ctrl.onChanged('[[Pr', 4);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.value.suggestions, ['Project Alpha']);
      expect(calls, 2);
    });
  });
}
