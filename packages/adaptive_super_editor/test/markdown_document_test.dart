import 'package:adaptive_super_editor/src/markdown_document.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:super_editor/super_editor.dart';

void main() {
  test('typed punctuation stays editable after a Markdown round trip', () {
    final draft = MarkdownEditingDocument.fromMarkdown('Start');
    _append(
      _editor(draft),
      draft.document.first.id,
      5,
      r' a < b costs $5 {{x | =',
    );
    final reparsed = MarkdownEditingDocument.fromMarkdown(draft.toMarkdown());
    expect(reparsed.document.first, isA<ParagraphNode>());
    expect(
      (reparsed.document.first as TextNode).text.toPlainText(),
      r'Start a < b costs $5 {{x | =',
    );
  });

  test('edited fence retains a language containing a backtick', () {
    final draft = MarkdownEditingDocument.fromMarkdown('~~~a`b\ncode\n~~~');
    _append(_editor(draft), draft.document.first.id, 4, '\n~~~~');
    final serialized = draft.toMarkdown();
    expect(serialized, '~~~~~a`b\ncode\n~~~~\n~~~~~');
    final reparsed = MarkdownEditingDocument.fromMarkdown(serialized);
    expect(reparsed.document.first, isA<TextNode>());
    final node = reparsed.document.first as TextNode;
    expect(node.getMetadataValue('blockType'), codeAttribution);
    expect(node.getMetadataValue('language'), 'a`b');
    expect(node.text.toPlainText(), 'code\n~~~~');
    expect(md.markdownToHtml(serialized), contains('<pre><code'));
  });

  test('all supported blocks retain exact CRLF source without edits', () {
    const source =
        '\r\n# H1  \r\n## H2\r\n### H3\r\n#### H4\r\n##### H5\r\n###### H6\r\n\r\nParagraph **bold** and _italic_.\r\n\r\n* bullet\r\n7) numbered\r\n- [X] done\r\n- [ ] todo\r\n\r\n> quoted\r\n> second line\r\n\r\n~~~dart\r\nprint(1);\r\n~~~\r\n\r\n***\r\n';
    final draft = MarkdownEditingDocument.fromMarkdown(source);

    expect(draft.toMarkdown(), source);
    expect(draft.document.nodeCount, 14);
    expect(draft.document.getNodeAt(7), isA<ListItemNode>());
    expect(draft.document.getNodeAt(9), isA<TaskNode>());
    expect(draft.document.last, isA<HorizontalRuleNode>());
  });

  test('unsupported blocks retain exact source beside an edit and undo', () {
    const tail =
        '| A | B |\r\n|---|---|\r\n|1|2|\r\n\r\n- parent\r\n  - child\r\n\r\n[ref]: /target "title"\r\n\r\n![image](/image.png)\r\n\r\n[[wiki]]\r\n\r\n```database\r\n{"id":"db"}\r\n```\r\n\r\n<div>raw</div>\r\n';
    final draft = MarkdownEditingDocument.fromMarkdown('Text\r\n\r\n$tail');
    final editor = _editor(draft);

    _append(editor, draft.document.first.id, 4, ' changed');

    expect(draft.toMarkdown(), 'Text changed\r\n\r\n$tail');
    expect(draft.document.getNodeAt(1), isA<OpaqueMarkdownNode>());
    editor.undo();
    expect(draft.toMarkdown(), 'Text\r\n\r\n$tail');
  });

  test(
    'moving source spans repairs paragraph boundaries and undo restores gaps',
    () {
      const source = '# Title\nParagraph\n\nOther';
      final draft = MarkdownEditingDocument.fromMarkdown(source);
      final editor = _editor(draft);

      editor.execute([
        MoveNodeRequest(nodeId: draft.document.last.id, newIndex: 1),
      ]);

      expect(draft.toMarkdown(), '# Title\n\nOther\n\nParagraph');
      editor.undo();
      expect(draft.toMarkdown(), source);
    },
  );

  test('deleting a divider keeps adjacent paragraphs separate', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      'First\n\n---\n\nSecond',
    );
    final editor = _editor(draft);

    editor.execute([
      DeleteNodeRequest(nodeId: draft.document.getNodeAt(1)!.id),
    ]);

    expect(draft.toMarkdown(), 'First\n\nSecond');
    editor.undo();
    expect(draft.toMarkdown(), 'First\n\n---\n\nSecond');
  });

  test(
    'source replacement keeps document identity and both undo provenances',
    () {
      const original = '# Old  \r\n\r\n| A |\r\n|---|\r\n';
      const replacement = '## New\n\n- [x] task\n';
      final draft = MarkdownEditingDocument.fromMarkdown(original);
      final document = draft.document;
      final editor = _editor(draft);

      draft.replaceMarkdown(replacement, editor);

      expect(identical(document, draft.document), isTrue);
      expect(draft.toMarkdown(), replacement);
      editor.undo();
      expect(draft.toMarkdown(), original);
      editor.redo();
      expect(draft.toMarkdown(), replacement);
    },
  );

  test('edited inline styles and links serialize without rewriting adjacent source', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      '**bold** _italic_ `code` [link](https://example.com)\n\n# untouched  ',
    );
    final editor = _editor(draft);
    final node = draft.document.first as TextNode;
    expect(node.text.toPlainText(), 'bold italic code link');
    expect(node.text.getAllAttributionsAt(0), contains(boldAttribution));
    expect(node.text.getAllAttributionsAt(5), contains(italicsAttribution));
    expect(node.text.getAllAttributionsAt(12), contains(codeAttribution));
    expect(
      node.text
          .getAllAttributionsAt(17)
          .whereType<LinkAttribution>()
          .single
          .plainTextUri,
      'https://example.com',
    );

    _append(editor, node.id, node.text.length, '!');

    expect(
      draft.toMarkdown(),
      '**bold** *italic* `code` [link](https://example.com)!\n\n# untouched  ',
    );
  });

  test('indented fences retain exact CRLF source and rendered code after edits', () {
    const source =
        '   ~~~python\r\n   value\r\n x\r\n     nested\r\n\tTabbed\r\n  \tMixed\r\n   ~~~\r\n';
    final draft = MarkdownEditingDocument.fromMarkdown(source);
    final node = draft.document.first as TextNode;
    final editor = _editor(draft);

    expect(draft.toMarkdown(), source);
    expect(node.text.toPlainText(), 'value\nx\n  nested\n\tTabbed\n\tMixed');

    _append(editor, node.id, node.text.length, '!');

    expect(
      md.markdownToHtml(draft.toMarkdown()),
      '<pre><code class="language-python">value\nx\n  nested\n\tTabbed\n\tMixed!\n</code></pre>\n',
    );
    editor.undo();
    expect(draft.toMarkdown(), source);
  });

  test(
    'editing indented backtick fences preserves intentional code spaces',
    () {
      final draft = MarkdownEditingDocument.fromMarkdown(
        '  ```dart\n  first\n    second\n  ```',
      );
      final node = draft.document.first as TextNode;
      final editor = _editor(draft);

      _append(editor, node.id, node.text.length, '\n  third');

      expect(
        md.markdownToHtml(draft.toMarkdown()),
        '<pre><code class="language-dart">first\n  second\n  third\n</code></pre>\n',
      );
    },
  );

  test('edited code chooses a fence longer than embedded closing fences', () {
    final draft = MarkdownEditingDocument.fromMarkdown('```dart\nvalue\n```\n');
    final editor = _editor(draft);

    _append(editor, draft.document.first.id, 5, '\n```');

    expect(draft.toMarkdown(), '````dart\nvalue\n```\n````\n');
  });

  test('source lookup uses UTF16 ranges in the current serialization', () {
    const source = '😀 first\r\n\r\n# heading';
    final draft = MarkdownEditingDocument.fromMarkdown(source);
    final node = draft.document.last;

    expect(draft.sourceForNode(node.id), '# heading');
    final range = draft.sourceRangeForNode(node.id);
    expect(source.substring(range.start, range.end), '# heading');
  });

  test('paste provenance retains unusual spelling and uses distinct node identities', () {
    final draft = MarkdownEditingDocument.fromMarkdown('First');
    final fragment = MarkdownEditingDocument.fromMarkdown(
      '## Pasted ###  \r\n',
    );
    final editor = _editor(draft);
    expect(fragment.document.first.id, isNot(draft.document.first.id));
    draft.retainSources(fragment);

    editor.execute([
      ReplaceDocumentRequest([draft.document.first, fragment.document.first]),
    ]);

    expect(draft.toMarkdown(), 'First\n\n## Pasted ###  \r\n');
  });

  test(
    'empty whitespace draft remains exact and exposes an editable paragraph',
    () {
      final draft = MarkdownEditingDocument.fromMarkdown(' \r\n\t\r\n');

      expect(draft.document.first, isA<ParagraphNode>());
      expect(draft.toMarkdown(), ' \r\n\t\r\n');
    },
  );
  test('nested formatting remains nested after a neighboring text edit', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      '**bold _nested_ tail**',
    );
    final editor = _editor(draft);

    _append(editor, draft.document.first.id, 16, '!');

    expect(draft.toMarkdown(), '**bold *nested* tail**!');
  });

  test(
    'edited emphasis keeps surrounding whitespace outside its delimiters',
    () {
      final draft = MarkdownEditingDocument.fromMarkdown('text');
      final node = draft.document.first as TextNode;
      final editor = _editor(draft);
      editor.execute([
        ReplaceDocumentRequest([
          node.copyTextNodeWith(
            text: AttributedText(' text ')
              ..addAttribution(boldAttribution, const SpanRange(0, 5)),
          ),
        ]),
      ]);

      expect(draft.toMarkdown(), ' **text** ');
    },
  );

  test('literal paragraph list markers do not become structural Markdown', () {
    final draft = MarkdownEditingDocument.fromMarkdown('Text');
    final editor = _editor(draft);
    final node = draft.document.first as TextNode;

    editor.execute([
      ReplaceDocumentRequest([
        node.copyTextNodeWith(text: AttributedText('- literal')),
      ]),
    ]);

    expect(draft.toMarkdown(), r'\- literal');
    expect(
      MarkdownEditingDocument.fromMarkdown(draft.toMarkdown()).document.first,
      isA<ParagraphNode>(),
    );
  });

  test('nested list across a blank line is one opaque region', () {
    const source = '- parent\n\n  - child\n\nAfter';
    final draft = MarkdownEditingDocument.fromMarkdown(source);

    expect(draft.document.first, isA<OpaqueMarkdownNode>());
    expect(
      draft.sourceForNode(draft.document.first.id),
      '- parent\n\n  - child',
    );
    expect(draft.toMarkdown(), source);
  });

  test('unterminated fence keeps the complete draft opaque', () {
    const source = 'Before\n\n```dart\nunterminated\n';
    final draft = MarkdownEditingDocument.fromMarkdown(source);

    expect(draft.document.nodeCount, 1);
    expect(draft.document.first, isA<OpaqueMarkdownNode>());
    expect(draft.toMarkdown(), source);
  });

  test('source offsets and source bodies update after neighboring edits', () {
    final draft = MarkdownEditingDocument.fromMarkdown('First\n\n# heading');
    final editor = _editor(draft);
    final heading = draft.document.last;

    _append(editor, draft.document.first.id, 5, ' longer');

    final range = draft.sourceRangeForNode(heading.id);
    expect(range.start, 14);
    expect(draft.toMarkdown().substring(range.start, range.end), '# heading');
  });

  test(
    'node conversion invalidates original source and repairs its boundary',
    () {
      final draft = MarkdownEditingDocument.fromMarkdown('# Title\nParagraph');
      final editor = _editor(draft);
      final node = draft.document.first;

      editor.execute([
        ReplaceDocumentRequest([
          node.copyWithAddedMetadata({'blockType': paragraphAttribution}),
          draft.document.last,
        ]),
      ]);

      expect(draft.toMarkdown(), 'Title\n\nParagraph');
      editor.undo();
      expect(draft.toMarkdown(), '# Title\nParagraph');
    },
  );

  test('opaque node copies keep independent metadata maps', () {
    final original = OpaqueMarkdownNode(
      id: 'opaque',
      source: '[[wiki]]',
      metadata: {'label': 'original'},
    );
    final copy = original.copyWithAddedMetadata({'label': 'copy'});

    expect(original.getMetadataValue('label'), 'original');
    expect(copy.getMetadataValue('label'), 'copy');
    expect(copy.rawMarkdown, '[[wiki]]');
  });
  test('HTML spanning blank lines stays one opaque region beside an edit', () {
    const html = '<div>\n\nRaw **text**\n\n</div>';
    final draft = MarkdownEditingDocument.fromMarkdown(
      'Before\n\n$html\n\nAfter',
    );
    final editor = _editor(draft);

    _append(editor, draft.document.first.id, 6, '!');

    expect(draft.document.nodeCount, 3);
    expect(draft.document.getNodeAt(1), isA<OpaqueMarkdownNode>());
    expect(draft.sourceForNode(draft.document.getNodeAt(1)!.id), html);
    expect(draft.toMarkdown(), 'Before!\n\n$html\n\nAfter');
  });

  test('lazy list continuation remains part of an opaque list', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      '- item\ncontinuation\n\nAfter',
    );

    expect(draft.document.first, isA<OpaqueMarkdownNode>());
    expect(
      draft.sourceForNode(draft.document.first.id),
      '- item\ncontinuation',
    );
    expect(draft.document.nodeCount, 2);
  });

  test(
    'opaque metadata snapshots reject mutations including nested values',
    () {
      final metadata = <String, dynamic>{
        'nested': <String, dynamic>{'label': 'original'},
      };
      final node = OpaqueMarkdownNode(
        id: 'opaque',
        source: '[[wiki]]',
        metadata: metadata,
      );
      (metadata['nested'] as Map<String, dynamic>)['label'] = 'changed';

      expect((node.metadata['nested'] as Map)['label'], 'original');
      expect(() => node.metadata['extra'] = 'value', throwsUnsupportedError);
      expect(
        () => (node.metadata['nested'] as Map)['label'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );
  test('edited literal entities and indentation remain paragraph text', () {
    final draft = MarkdownEditingDocument.fromMarkdown('Text');
    final editor = _editor(draft);
    final node = draft.document.first as TextNode;
    editor.execute([
      ReplaceDocumentRequest([
        node.copyTextNodeWith(text: AttributedText('    &copy;')),
      ]),
    ]);

    final reparsed = MarkdownEditingDocument.fromMarkdown(draft.toMarkdown());
    expect(reparsed.document.first, isA<ParagraphNode>());
    expect(
      (reparsed.document.first as TextNode).text.toPlainText(),
      '    &copy;',
    );
  });

  test('escaped numbered literal retains its original closing punctuation', () {
    final draft = MarkdownEditingDocument.fromMarkdown('Text');
    final editor = _editor(draft);
    final node = draft.document.first as TextNode;
    editor.execute([
      ReplaceDocumentRequest([
        node.copyTextNodeWith(text: AttributedText('1) literal')),
      ]),
    ]);

    final reparsed = MarkdownEditingDocument.fromMarkdown(draft.toMarkdown());
    expect(
      (reparsed.document.first as TextNode).text.toPlainText(),
      '1) literal',
    );
  });
  test('lazy quote continuation stays in its opaque quote region', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      '> quote\ncontinuation\n\nAfter',
    );

    expect(draft.document.first, isA<OpaqueMarkdownNode>());
    expect(
      draft.sourceForNode(draft.document.first.id),
      '> quote\ncontinuation',
    );
    expect(draft.document.nodeCount, 2);
  });

  test(
    'nested HTML closing tags do not expose inner source as editable blocks',
    () {
      const html = '<div><div>Inner</div>\n\nRaw text\n\n</div>';
      final draft = MarkdownEditingDocument.fromMarkdown('$html\n\nAfter');

      expect(draft.document.first, isA<OpaqueMarkdownNode>());
      expect(draft.sourceForNode(draft.document.first.id), html);
      expect(draft.document.nodeCount, 2);
    },
  );
  test('wiki links remain editable and preserve raw syntax beside an edit', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      'See [[Another note]] today.',
    );
    final editor = _editor(draft);
    final node = draft.document.first;

    expect(node, isA<ParagraphNode>());
    expect(
      (node as TextNode).text.getAllAttributionsAt(4),
      contains(wikiLinkAttribution),
    );
    _append(editor, node.id, 27, '!');

    expect(draft.toMarkdown(), 'See [[Another note]] today.!');
    editor.undo();
    expect(draft.toMarkdown(), 'See [[Another note]] today.');
  });

  test('newly typed wiki tokens serialize without escaping their brackets', () {
    final draft = MarkdownEditingDocument.fromMarkdown('See ');
    final editor = _editor(draft);

    _append(editor, draft.document.first.id, 4, '[[Another note]]');

    expect(draft.toMarkdown(), 'See [[Another note]]');
  });

  test('incomplete wiki input stays raw for autocomplete', () {
    final draft = MarkdownEditingDocument.fromMarkdown('See ');
    final editor = _editor(draft);

    _append(editor, draft.document.first.id, 4, '[[Ano');

    expect(draft.toMarkdown(), 'See [[Ano');
  });

  test('escaped literal wiki brackets stay escaped beside an edit', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      r'See \[\[literal\]\] today.',
    );
    final editor = _editor(draft);
    final node = draft.document.first;

    expect(node, isA<ParagraphNode>());
    expect((node as TextNode).text.toPlainText(), 'See [[literal]] today.');
    _append(editor, node.id, node.text.length, '!');

    expect(draft.toMarkdown(), r'See \[\[literal\]\] today.!');
  });

  test('escaped literals and real wiki links retain distinct semantics', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      r'\[\[literal\]\] and [[Real note]]',
    );
    final editor = _editor(draft);
    final node = draft.document.first;

    expect(node, isA<ParagraphNode>());
    _append(editor, node.id, (node as TextNode).text.length, '!');

    expect(draft.toMarkdown(), r'\[\[literal\]\] and [[Real note]]!');
  });

  test('wiki embeds remain opaque', () {
    const source = '![[Another note]]';
    final draft = MarkdownEditingDocument.fromMarkdown(source);

    expect(draft.document.first, isA<OpaqueMarkdownNode>());
    expect(draft.toMarkdown(), source);
  });

  test('wiki titles keep punctuation that otherwise belongs to unsupported inline syntax', () {
    final draft = MarkdownEditingDocument.fromMarkdown(
      r'See [[Costs $5 <today>]]',
    );
    final node = draft.document.first;
    final editor = _editor(draft);

    expect(node, isA<ParagraphNode>());
    _append(editor, node.id, (node as TextNode).text.length, '!');

    expect(draft.toMarkdown(), r'See [[Costs $5 <today>]]!');
  });

  test('formatting around wiki tokens survives neighboring edits', () {
    final draft = MarkdownEditingDocument.fromMarkdown('**[[Another note]]**');
    final editor = _editor(draft);
    final node = draft.document.first as TextNode;

    _append(editor, node.id, node.text.length, '!');

    expect(draft.toMarkdown(), '**[[Another note]]**!');
  });
}

Editor _editor(MarkdownEditingDocument draft) {
  final composer = MutableDocumentComposer();
  final editor = createMarkdownDocumentEditor(
    document: draft.document,
    composer: composer,
    isHistoryEnabled: true,
  );
  addTearDown(editor.dispose);
  addTearDown(composer.dispose);
  return editor;
}

void _append(Editor editor, String id, int offset, String text) {
  editor.execute([
    InsertTextRequest(
      documentPosition: DocumentPosition(
        nodeId: id,
        nodePosition: TextNodePosition(offset: offset),
      ),
      textToInsert: text,
      attributions: {},
    ),
  ]);
}
