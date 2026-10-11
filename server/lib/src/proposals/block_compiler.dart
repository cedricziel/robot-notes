import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:server/src/markdown_blocks.dart';
import 'package:server/src/proposals/proposal_operation.dart';
import 'package:ulid/ulid.dart';

String _hash(String text) => sha256.convert(utf8.encode(text)).toString();

/// A reviewed insertion boundary derived from accepted source.
class ProposalInsertionGap {
  /// Captures the following accepted block and exact intervening whitespace.
  const ProposalInsertionGap({required this.beforeBlockId, required this.hash});

  /// Loads server-captured review context from a retained proposal version.
  factory ProposalInsertionGap.fromJson(Map<String, dynamic> json) =>
      ProposalInsertionGap(
        beforeBlockId: json['before_block_id'] as String?,
        hash: json['hash'] as String,
      );

  /// Following block identity; null for the terminal or empty-document gap.
  final String? beforeBlockId;

  /// Hash of the exact accepted gap source.
  final String hash;

  /// Serializes immutable review context separately from operation input.
  Map<String, Object?> toJson() =>
      {'before_block_id': beforeBlockId, 'hash': hash};
}

/// A stale or structurally ambiguous block operation cannot be committed.
class ProposalBlockConflictException implements Exception {
  /// Reports a machine-readable reason without exposing source content.
  const ProposalBlockConflictException(this.reason, {this.blockId});

  /// Freshness or scope check that failed.
  final String reason;

  /// Affected block identity when known.
  final String? blockId;
}

/// A reviewed candidate remains unaccepted until the review service commits it.
class CompiledBlockProposal {
  CompiledBlockProposal._({
    required this.content,
    required this.blockMap,
    required this.deleted,
    required Set<String> touchedIds,
  }) : touchedIds = Set.unmodifiable(touchedIds);

  /// Exact candidate body with untouched source and whitespace preserved.
  final String content;

  /// Candidate identities for the next accepted revision.
  final MarkdownBlockMap blockMap;

  /// True only for an exclusive, whole-note deletion operation.
  final bool deleted;

  /// Explicit accepted targets whose freshness was checked.
  final Set<String> touchedIds;
}

/// Applies precise reviewed source edits without guessing duplicate identities.
class ProposalBlockCompiler {
  /// Shares source parsing while keeping new identities opaque.
  ProposalBlockCompiler({
    MarkdownBlockReconciler? reconciler,
    String Function()? idGenerator,
  })  : _reconciler = reconciler ?? MarkdownBlockReconciler(),
        _idGenerator = idGenerator ?? (() => Ulid().toString());

  final MarkdownBlockReconciler _reconciler;
  final String Function() _idGenerator;

  /// Captures insertion boundaries from an authorized accepted base.
  Map<int, ProposalInsertionGap> captureGaps(
    String source,
    MarkdownBlockMap map,
    List<ProposalOperation> operations,
  ) {
    if (!map.matches(source)) {
      throw const ProposalBlockConflictException('block_map_stale');
    }
    final gaps = <int, ProposalInsertionGap>{};
    for (var i = 0; i < operations.length; i++) {
      final operation = operations[i];
      if (operation.type != 'insert_after') continue;
      final position = _gap(source, map, operation);
      gaps[i] = position.context;
    }
    return Map.unmodifiable(gaps);
  }

  /// Checks current touched blocks before producing an exact candidate.
  /// Unrelated newer note versions can merge; whole-note deletion cannot.
  CompiledBlockProposal compile(
    String source,
    MarkdownBlockMap map,
    List<ProposalOperation> operations, {
    required int baseVersion,
    Map<int, ProposalInsertionGap> gaps = const {},
  }) {
    if (!map.matches(source)) {
      throw const ProposalBlockConflictException('block_map_stale');
    }
    if (baseVersion < 1 || baseVersion > map.version || operations.isEmpty) {
      throw const ProposalBlockConflictException('invalid_accepted_base');
    }
    if (operations.any((op) => op.type == 'delete_note')) {
      if (operations.length != 1 || baseVersion != map.version) {
        throw const ProposalBlockConflictException('whole_note_changed');
      }
      return CompiledBlockProposal._(
        content: '',
        blockMap: _reconciler.reconcile(
          '',
          version: map.version + 1,
          previous: map,
          previousSource: source,
        ),
        deleted: true,
        touchedIds: map.blocks.map((b) => b.id).toSet(),
      );
    }
    final touched = <String>{};
    final deleted = <String>{};
    final edits = <_SourceEdit>[];
    for (var i = 0; i < operations.length; i++) {
      final operation = operations[i];
      final id = operation.blockId;
      MarkdownBlock? block;
      if (id != null) {
        final candidates = map.blocks.where((b) => b.id == id);
        if (candidates.isEmpty) {
          throw ProposalBlockConflictException('block_removed', blockId: id);
        }
        block = candidates.single;
        if (block.revision != operation.expectedRevision) {
          throw ProposalBlockConflictException('block_changed', blockId: id);
        }
        touched.add(id);
      }
      switch (operation.type) {
        case 'replace':
          edits.add(_SourceEdit(block!.start, block.end, operation.text!, i));
        case 'delete':
          edits.add(_SourceEdit(block!.start, block.end, '', i));
          deleted.add(block.id);
        case 'insert_after':
          final current = _gap(source, map, operation);
          final expected = gaps[i];
          if (expected == null ||
              expected.beforeBlockId != current.context.beforeBlockId ||
              expected.hash != current.context.hash) {
            throw ProposalBlockConflictException(
              'insertion_gap_changed',
              blockId: id,
            );
          }
          edits.add(_SourceEdit(current.end, current.end, operation.text!, i));
        case 'attach_evidence':
          break;
        default:
          throw const FormatException('Unsupported block operation');
      }
    }
    edits.sort((a, b) {
      final start = a.start.compareTo(b.start);
      if (start != 0) return start;
      final end = a.end.compareTo(b.end);
      return end != 0 ? end : a.operationIndex.compareTo(b.operationIndex);
    });
    final buffer = StringBuffer();
    var cursor = 0;
    for (final edit in edits) {
      if (edit.start < cursor) {
        throw const ProposalBlockConflictException('overlapping_source_edits');
      }
      buffer
        ..write(source.substring(cursor, edit.start))
        ..write(edit.text);
      cursor = edit.end;
    }
    buffer.write(source.substring(cursor));
    final content = buffer.toString();
    final candidate = _reconciler.reconcile(
      content,
      version: map.version + 1,
      previous: map,
      previousSource: source,
    );
    final hints = <int, MarkdownBlock>{};
    final changed = <String>{};
    for (final prior in map.blocks) {
      if (deleted.contains(prior.id)) continue;
      final start =
          _translate(prior.start, edits, includeBoundaryInsertion: true);
      final end = _translate(prior.end, edits, includeBoundaryInsertion: false);
      final exact = candidate.blocks.indexWhere(
        (b) => b.start == start && b.end == end && b.kind == prior.kind,
      );
      var index = exact;
      if (index < 0 && touched.contains(prior.id)) {
        index = candidate.blocks.indexWhere(
          (b) => b.start == start && b.end >= end && b.kind == prior.kind,
        );
      }
      if (index < 0) {
        if (!touched.contains(prior.id)) {
          throw ProposalBlockConflictException(
            'undeclared_structure_change',
            blockId: prior.id,
          );
        }
        continue;
      }
      final span = candidate.blocks[index];
      final same = span.source(content) == prior.source(source);
      if (!same && !touched.contains(prior.id)) {
        throw ProposalBlockConflictException(
          'undeclared_structure_change',
          blockId: prior.id,
        );
      }
      if (!same &&
          !const {'heading', 'paragraph', 'thematic'}.contains(span.kind)) {
        continue;
      }
      if (hints.containsKey(index)) {
        throw const ProposalBlockConflictException('ambiguous_source_identity');
      }
      hints[index] = prior;
      if (!same) changed.add(prior.id);
    }
    final oldIds = map.blocks.map((b) => b.id).toSet();
    final blocks = <MarkdownBlock>[];
    for (var i = 0; i < candidate.blocks.length; i++) {
      final span = candidate.blocks[i];
      final prior = hints[i];
      blocks.add(
        MarkdownBlock(
          id: prior?.id ??
              (oldIds.contains(span.id) ? _idGenerator() : span.id),
          revision: prior == null
              ? 1
              : prior.revision + (changed.contains(prior.id) ? 1 : 0),
          kind: span.kind,
          start: span.start,
          end: span.end,
          hash: span.hash,
        ),
      );
    }
    final retained = blocks.map((b) => b.id).toSet();
    final retired = map.blocks
        .where((b) => !retained.contains(b.id))
        .map((b) => b.id)
        .toList();
    return CompiledBlockProposal._(
      content: content,
      blockMap: MarkdownBlockMap(
        version: candidate.version,
        contentHash: candidate.contentHash,
        blocks: List.unmodifiable(blocks),
        changedIds: changed.toList(),
        retiredIds: retired,
        ambiguousIds: retired.where((id) => !deleted.contains(id)).toList(),
      ),
      deleted: false,
      touchedIds: touched,
    );
  }
}

({int end, ProposalInsertionGap context}) _gap(
  String source,
  MarkdownBlockMap map,
  ProposalOperation operation,
) {
  if (operation.blockId == null) {
    if (map.blocks.isNotEmpty) {
      throw const ProposalBlockConflictException('empty_document_changed');
    }
    return (
      end: source.length,
      context: ProposalInsertionGap(beforeBlockId: null, hash: _hash(source))
    );
  }
  final index = map.blocks.indexWhere((b) => b.id == operation.blockId);
  if (index < 0 || map.blocks[index].revision != operation.expectedRevision) {
    throw ProposalBlockConflictException(
      'block_changed',
      blockId: operation.blockId,
    );
  }
  final before = index + 1 < map.blocks.length ? map.blocks[index + 1] : null;
  final end = before?.start ?? source.length;
  return (
    end: end,
    context: ProposalInsertionGap(
      beforeBlockId: before?.id,
      hash: _hash(source.substring(map.blocks[index].end, end)),
    )
  );
}

class _SourceEdit {
  const _SourceEdit(this.start, this.end, this.text, this.operationIndex);
  final int start;
  final int end;
  final String text;
  final int operationIndex;
}

int _translate(
  int offset,
  List<_SourceEdit> edits, {
  required bool includeBoundaryInsertion,
}) {
  var result = offset;
  for (final edit in edits) {
    if (edit.end < offset ||
        (edit.end == offset &&
            (edit.start != edit.end || includeBoundaryInsertion))) {
      result += edit.text.length - (edit.end - edit.start);
    }
  }
  return result;
}
