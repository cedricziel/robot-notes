import 'package:server/src/markdown_blocks.dart';
import 'package:server/src/proposals/block_compiler.dart';
import 'package:server/src/proposals/proposal_operation.dart';
import 'package:test/test.dart';

void main() {
  var nextId = 0;
  late MarkdownBlockReconciler reconciler;
  late ProposalBlockCompiler compiler;
  setUp(() {
    nextId = 0;
    String id() => 'block-${nextId++}';
    reconciler = MarkdownBlockReconciler(idGenerator: id);
    compiler = ProposalBlockCompiler(reconciler: reconciler, idGenerator: id);
  });

  test('replaces one block without changing CRLF or surrounding gaps', () {
    const source = '# Title\r\n\r\nold\r\n\r\nlast';
    final map = reconciler.reconcile(source, version: 1);
    final operations = ProposalOperation.parseAll([
      {
        'type': 'replace',
        'block_id': map.blocks[1].id,
        'expected_revision': 1,
        'text': 'new\r\n',
      },
    ]);

    final result = compiler.compile(source, map, operations, baseVersion: 1);

    expect(result.content, '# Title\r\n\r\nnew\r\n\r\nlast');
    expect(
      result.blockMap.blocks.map((b) => b.id),
      map.blocks.map((b) => b.id),
    );
    expect(result.blockMap.blocks[1].revision, 2);
  });

  test('explicit disjoint edits preserve duplicate block identities', () {
    const source = 'same\n\nsame\n';
    final original = reconciler.reconcile(source, version: 1);
    final first = compiler.compile(
      source,
      original,
      ProposalOperation.parseAll([
        {
          'type': 'replace',
          'block_id': original.blocks[0].id,
          'expected_revision': 1,
          'text': 'first\n',
        },
      ]),
      baseVersion: 1,
    );

    final second = compiler.compile(
      first.content,
      first.blockMap,
      ProposalOperation.parseAll([
        {
          'type': 'replace',
          'block_id': original.blocks[1].id,
          'expected_revision': 1,
          'text': 'second\n',
        },
      ]),
      baseVersion: 1,
    );

    expect(second.content, 'first\n\nsecond\n');
    expect(
      second.blockMap.blocks.map((b) => b.id),
      original.blocks.map((b) => b.id),
    );
    expect(second.blockMap.blocks.map((b) => b.revision), [2, 2]);
  });

  test('same-block stale edits fail without a compiled accepted candidate', () {
    const source = 'old';
    final original = reconciler.reconcile(source, version: 1);
    final operations = ProposalOperation.parseAll([
      {
        'type': 'replace',
        'block_id': original.blocks.single.id,
        'expected_revision': 1,
        'text': 'new',
      },
    ]);
    final current =
        compiler.compile(source, original, operations, baseVersion: 1);

    expect(
      () => compiler.compile(
        current.content,
        current.blockMap,
        operations,
        baseVersion: 1,
      ),
      throwsA(isA<ProposalBlockConflictException>()),
    );
  });

  test('concurrent changes to the same insertion gap require re-review', () {
    const source = 'first\n\nlast';
    final map = reconciler.reconcile(source, version: 1);
    final operations = ProposalOperation.parseAll([
      {
        'type': 'insert_after',
        'block_id': map.blocks.first.id,
        'expected_revision': 1,
        'text': 'middle\n\n',
      },
    ]);
    final gaps = compiler.captureGaps(source, map, operations);
    final first = compiler.compile(
      source,
      map,
      operations,
      baseVersion: 1,
      gaps: gaps,
    );

    expect(
      () => compiler.compile(
        first.content,
        first.blockMap,
        operations,
        baseVersion: 1,
        gaps: gaps,
      ),
      throwsA(isA<ProposalBlockConflictException>()),
    );
  });

  test('empty-map insertion preserves whitespace-only content before append',
      () {
    const source = '  \n\n';
    final map = reconciler.reconcile(source, version: 1);
    final operations = ProposalOperation.parseAll([
      {
        'type': 'insert_after',
        'block_id': null,
        'expected_revision': null,
        'text': 'first',
      },
    ]);
    final gaps = compiler.captureGaps(source, map, operations);

    final result = compiler.compile(
      source,
      map,
      operations,
      baseVersion: 1,
      gaps: gaps,
    );

    expect(result.content, '  \n\nfirst');
  });

  test('unsupported structure cannot absorb an undeclared neighbor', () {
    const source = 'first\n\n# Neighbor\n';
    final map = reconciler.reconcile(source, version: 1);
    final operations = ProposalOperation.parseAll([
      {
        'type': 'replace',
        'block_id': map.blocks.first.id,
        'expected_revision': 1,
        'text': '<custom>\n',
      },
    ]);

    expect(
      () => compiler.compile(source, map, operations, baseVersion: 1),
      throwsA(isA<ProposalBlockConflictException>()),
    );
  });

  test(
      'deleting a block does not transfer its ID to replacement text elsewhere',
      () {
    const source = 'first\n\nsecond\n';
    final map = reconciler.reconcile(source, version: 1);
    final operations = ProposalOperation.parseAll([
      {'type': 'delete', 'block_id': map.blocks[0].id, 'expected_revision': 1},
      {
        'type': 'replace',
        'block_id': map.blocks[1].id,
        'expected_revision': 1,
        'text': 'first\n',
      },
    ]);

    final result = compiler.compile(source, map, operations, baseVersion: 1);

    expect(result.blockMap.blocks.single.id, map.blocks[1].id);
    expect(result.blockMap.retiredIds, [map.blocks[0].id]);
  });

  test('whole-note deletion requires the exact accepted note version', () {
    const source = 'body';
    final map = reconciler.reconcile(source, version: 2);
    final operations = ProposalOperation.parseAll([
      {'type': 'delete_note'},
    ]);

    expect(
      () => compiler.compile(source, map, operations, baseVersion: 1),
      throwsA(isA<ProposalBlockConflictException>()),
    );
  });

  test('evidence attachment preserves accepted text and block revisions', () {
    const source = 'body';
    final map = reconciler.reconcile(source, version: 1);
    final operations = ProposalOperation.parseAll([
      {
        'type': 'attach_evidence',
        'block_id': map.blocks.single.id,
        'expected_revision': 1,
        'evidence_refs': [
          {'kind': 'unknown', 'reason': 'source_not_recorded'},
        ],
      },
    ]);

    final result = compiler.compile(source, map, operations, baseVersion: 1);

    expect(result.content, source);
    expect(result.blockMap.blocks.single.id, map.blocks.single.id);
    expect(result.blockMap.blocks.single.revision, 1);
  });
}
