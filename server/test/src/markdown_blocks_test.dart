import 'package:server/src/markdown_blocks.dart';
import 'package:test/test.dart';

void main() {
  var nextId = 0;
  late MarkdownBlockReconciler reconciler;
  setUp(() {
    nextId = 0;
    reconciler =
        MarkdownBlockReconciler(idGenerator: () => 'block-${nextId++}');
  });

  test('source spans preserve CRLF, Unicode, whitespace and missing newline',
      () {
    const source =
        '\r\n# Title  \r\n\r\n𝄞 paragraph\r\n  continued\r\n\r\nlast';
    final map = reconciler.reconcile(source, version: 1);
    expect(map.blocks.map((b) => b.source(source)), [
      '# Title  \r\n',
      '𝄞 paragraph\r\n  continued\r\n',
      'last',
    ]);
  });

  test('compound blocks keep fenced content and internal lines together', () {
    const source = '- item\n  continuation\n\n  second paragraph\n\n'
        '| A | B |\n| --- | --- |\n| x | y |\n\n'
        '```md\n# inside\n\nparagraph\n```\n\n# Outside\n';
    final map = reconciler.reconcile(source, version: 1);
    expect(
      map.blocks.map((b) => b.kind),
      ['list', 'table', 'fence', 'heading'],
    );
    expect(map.blocks[2].source(source), '```md\n# inside\n\nparagraph\n```\n');
  });

  test('unknown embedded constructs keep the remainder opaque', () {
    const source = '# Before\n\n<custom>\n\n# Inner\n\n</custom>\n';
    final map = reconciler.reconcile(source, version: 1);
    expect(map.blocks.map((b) => b.kind), ['heading', 'opaque']);
    expect(
      map.blocks.last.source(source),
      '<custom>\n\n# Inner\n\n</custom>\n',
    );
  });

  test('unknown constructs after a list cannot expose speculative anchors', () {
    const source = '- item\n<custom>\n\n# Inner\n\n</custom>\n';

    final map = reconciler.reconcile(source, version: 1);

    expect(map.blocks.map((b) => b.kind), ['list', 'opaque']);
    expect(
      map.blocks.last.source(source),
      '<custom>\n\n# Inner\n\n</custom>\n',
    );
  });

  test('an unindented heading ends a preceding compound block', () {
    const source = '- item\n# Outside\n';

    final map = reconciler.reconcile(source, version: 1);

    expect(map.blocks.map((b) => b.kind), ['list', 'heading']);
  });

  test('unchanged duplicate blocks preserve identity', () {
    const source = 'same\n\nsame\n';
    final before = reconciler.reconcile(source, version: 1);
    final after = reconciler.reconcile(
      source,
      version: 2,
      previous: before,
      previousSource: source,
    );
    expect(after.blocks.map((b) => b.id), before.blocks.map((b) => b.id));
    expect(after.blocks.map((b) => b.revision), [1, 1]);
  });

  test('unique moved blocks retain identity and revision', () {
    const source = 'first\n\nsecond\n\nthird\n';
    final before = reconciler.reconcile(source, version: 1);
    final after = reconciler.reconcile(
      'third\n\nfirst\n\nsecond\n',
      version: 2,
      previous: before,
      previousSource: source,
    );
    expect(after.blocks.map((b) => b.id), ['block-2', 'block-0', 'block-1']);
    expect(after.blocks.map((b) => b.revision), [1, 1, 1]);
  });

  test('unambiguous edited block retains ID and increments revision', () {
    const source = '# Title\n\nold\n\n# End\n';
    final before = reconciler.reconcile(source, version: 1);
    final after = reconciler.reconcile(
      '# Title\n\nnew\n\n# End\n',
      version: 2,
      previous: before,
      previousSource: source,
    );
    expect(after.blocks[1].id, before.blocks[1].id);
    expect(after.blocks[1].revision, 2);
    expect(after.changedIds, ['block-1']);
  });

  test('changed repeated blocks report ambiguity and receive fresh IDs', () {
    const source = 'same\n\nsame\n\n# End\n';
    final before = reconciler.reconcile(source, version: 1);
    final after = reconciler.reconcile(
      'same\n\nsame\n\n# Different\n',
      version: 2,
      previous: before,
      previousSource: source,
    );
    expect(after.blocks.take(2).map((b) => b.id), ['block-3', 'block-4']);
    expect(after.ambiguousIds, containsAll(['block-0', 'block-1']));
  });

  test('split blocks retire the prior identity', () {
    const source = '# Title\n\njoined lines\n\n# End\n';
    final before = reconciler.reconcile(source, version: 1);
    final after = reconciler.reconcile(
      '# Title\n\njoined\n\nlines\n\n# End\n',
      version: 2,
      previous: before,
      previousSource: source,
    );
    expect(after.retiredIds, ['block-1']);
    expect(after.ambiguousIds, ['block-1']);
    expect(
      after.blocks.map((b) => b.id),
      ['block-0', 'block-3', 'block-4', 'block-2'],
    );
  });

  test('merged blocks retire all prior identities', () {
    const source = '# Title\n\nfirst\n\nsecond\n\n# End\n';
    final before = reconciler.reconcile(source, version: 1);

    final after = reconciler.reconcile(
      '# Title\n\nfirst second\n\n# End\n',
      version: 2,
      previous: before,
      previousSource: source,
    );

    expect(after.retiredIds, ['block-1', 'block-2']);
    expect(after.ambiguousIds, ['block-1', 'block-2']);
    expect(after.blocks[1].id, 'block-4');
  });

  test('changed compound blocks receive fresh identities', () {
    const source = '# Title\n\n- old\n\n# End\n';
    final before = reconciler.reconcile(source, version: 1);

    final after = reconciler.reconcile(
      '# Title\n\n- new\n\n# End\n',
      version: 2,
      previous: before,
      previousSource: source,
    );

    expect(after.blocks[1].id, 'block-3');
    expect(after.ambiguousIds, ['block-1']);
  });

  test('blank-line changes retain stable blocks with updated offsets', () {
    const source = '# Title\n\ntext';
    final before = reconciler.reconcile(source, version: 1);

    final after = reconciler.reconcile(
      '# Title\n\n\ntext',
      version: 2,
      previous: before,
      previousSource: source,
    );

    expect(after.blocks[1].id, before.blocks[1].id);
    expect(after.blocks[1].revision, 1);
    expect(after.blocks[1].start, before.blocks[1].start + 1);
  });

  test('mismatched accepted source cannot supply identities', () {
    final before = reconciler.reconcile('old\n', version: 1);
    final after = reconciler.reconcile(
      'new\n',
      version: 2,
      previous: before,
      previousSource: 'externally changed\n',
    );
    expect(after.blocks.single.id, 'block-1');
    expect(after.ambiguousIds, ['block-0']);
  });
}
