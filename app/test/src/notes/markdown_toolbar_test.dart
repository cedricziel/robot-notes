import 'package:app/src/notes/markdown_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _value(String text, int start, int end) => TextEditingValue(
  text: text,
  selection: TextSelection(baseOffset: start, extentOffset: end),
);

void main() {
  group('wrapSelection', () {
    test('wraps a non-empty selection and keeps it selected', () {
      final result = wrapSelection(_value('hello world', 6, 11), '**');
      expect(result.text, 'hello **world**');
      expect(
        result.selection,
        const TextSelection(baseOffset: 8, extentOffset: 13),
      );
    });

    test('inserts an empty pair and places the cursor between them', () {
      final result = wrapSelection(_value('hello ', 6, 6), '*');
      expect(result.text, 'hello **');
      expect(result.selection, const TextSelection.collapsed(offset: 7));
    });
  });

  group('insertMarkdownLink', () {
    test(
      'wraps a non-empty selection as a link, selecting the url placeholder',
      () {
        final result = insertMarkdownLink(_value('see docs', 4, 8));
        expect(result.text, 'see [docs](url)');
        expect(
          result.selection,
          const TextSelection(baseOffset: 11, extentOffset: 14),
        );
      },
    );

    test('inserts a link template and selects the title placeholder', () {
      final result = insertMarkdownLink(_value('see ', 4, 4));
      expect(result.text, 'see [title](url)');
      expect(
        result.selection,
        const TextSelection(baseOffset: 5, extentOffset: 10),
      );
    });
  });

  group('toggleLinePrefix', () {
    test('adds the prefix to the current line', () {
      final result = toggleLinePrefix(_value('hello', 2, 2), '# ');
      expect(result.text, '# hello');
      expect(result.selection, const TextSelection.collapsed(offset: 4));
    });

    test('removes the prefix if the line already has it', () {
      final result = toggleLinePrefix(_value('# hello', 4, 4), '# ');
      expect(result.text, 'hello');
      expect(result.selection, const TextSelection.collapsed(offset: 2));
    });

    test('does not throw when the cursor is at position 0', () {
      final result = toggleLinePrefix(_value('world', 0, 0), '# ');
      expect(result.text, '# world');
      expect(result.selection, const TextSelection.collapsed(offset: 2));
    });

    test('applies to the line containing the cursor within multiline text', () {
      final result = toggleLinePrefix(_value('one\ntwo\nthree', 5, 5), '- ');
      expect(result.text, 'one\n- two\nthree');
      expect(result.selection, const TextSelection.collapsed(offset: 7));
    });
  });
}
