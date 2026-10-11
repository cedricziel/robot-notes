import 'package:server/src/proposals/evidence_reference.dart';

/// A requested change against accepted block identity and revision.
class ProposalOperation {
  ProposalOperation._({
    required this.type,
    this.blockId,
    this.expectedRevision,
    this.text,
    List<EvidenceReference> evidenceRefs = const [],
    List<EvidenceReference> supersedes = const [],
  })  : evidenceRefs = List.unmodifiable(evidenceRefs),
        supersedes = List.unmodifiable(supersedes);

  /// Validates caller input without accepting review or identity overrides.
  factory ProposalOperation.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    final extras = switch (type) {
      'replace' || 'insert_after' => const [
          'text',
          'evidence_refs',
          'supersedes',
        ],
      'attach_evidence' => const ['evidence_refs', 'supersedes'],
      'delete' || 'delete_note' => const <String>[],
      _ => throw const FormatException('Unknown proposal operation'),
    };
    final blockFields = type == 'delete_note'
        ? const <String>[]
        : const ['block_id', 'expected_revision'];
    final allowed = {'type', ...blockFields, ...extras};
    if (!json.keys.every(allowed.contains)) {
      throw const FormatException('Unsupported proposal operation field');
    }
    final blockId = json['block_id'];
    final revision = json['expected_revision'];
    final emptyDocument = type == 'insert_after' && blockId == null;
    if (type != 'delete_note') {
      if (emptyDocument) {
        if (revision != null) {
          throw const FormatException(
            'Empty-document insertion has no block revision',
          );
        }
      } else if (blockId is! String ||
          blockId.trim().isEmpty ||
          revision is! int ||
          revision < 1) {
        throw const FormatException('Block identity and revision are required');
      }
    }
    final text = json['text'];
    if (extras.contains('text') &&
        (text is! String || (type == 'insert_after' && text.isEmpty))) {
      throw const FormatException('Operation Markdown text is required');
    }
    final evidence = _references(json['evidence_refs']);
    final supersedes = _references(json['supersedes']);
    if (type == 'attach_evidence' && evidence.isEmpty) {
      throw const FormatException('Evidence attachment cannot be empty');
    }
    if (supersedes.any(
      (ref) => !const {'note_revision', 'block_revision'}.contains(ref.kind),
    )) {
      throw const FormatException(
        'Supersession requires accepted source identity',
      );
    }
    return ProposalOperation._(
      type: type as String,
      blockId: blockId as String?,
      expectedRevision: revision as int?,
      text: text as String?,
      evidenceRefs: evidence,
      supersedes: supersedes,
    );
  }

  /// Rejects overlapping or contradictory operations before any mutation.
  static List<ProposalOperation> parseAll(Object? raw) {
    if (raw is! List<dynamic> || raw.isEmpty) {
      throw const FormatException(
        'Proposal operations must be a non-empty list',
      );
    }
    final operations = <ProposalOperation>[];
    for (final value in raw) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Proposal operation must be an object');
      }
      operations.add(ProposalOperation.fromJson(value));
    }
    if (operations.length > 1 &&
        operations.any((op) => op.type == 'delete_note')) {
      throw const FormatException('Whole-note deletion must be exclusive');
    }
    final changed = <String>{};
    final deleted = <String>{};
    final revisions = <String, int>{};
    for (final operation in operations) {
      final id = operation.blockId;
      if (id == null) continue;
      if (const {'replace', 'delete'}.contains(operation.type) &&
          !changed.add(id)) {
        throw const FormatException(
          'A block has contradictory content changes',
        );
      }
      if (operation.type == 'delete') deleted.add(id);
      final revision = operation.expectedRevision!;
      if (revisions.containsKey(id) && revisions[id] != revision) {
        throw const FormatException('A block has contradictory base revisions');
      }
      revisions[id] = revision;
    }
    if (operations.any(
      (op) =>
          op.type != 'delete' &&
          op.blockId != null &&
          deleted.contains(op.blockId),
    )) {
      throw const FormatException(
        'A deleted block cannot receive another operation',
      );
    }
    return List.unmodifiable(operations);
  }

  /// Declared operation; stored state and review authority are separate.
  final String type;

  /// Accepted target block, or null for deletion and empty-document insertion.
  final String? blockId;

  /// Required current block revision at acceptance.
  final int? expectedRevision;

  /// Exact replacement or insertion source, including caller-chosen whitespace.
  final String? text;

  /// Explicit supporting source references; none implicitly establishes truth.
  final List<EvidenceReference> evidenceRefs;

  /// Accepted source identities superseded by the reviewed destination block.
  final List<EvidenceReference> supersedes;

  /// Serializes public request fields without server-issued review context.
  Map<String, Object?> toJson() => {
        'type': type,
        if (type != 'delete_note') 'block_id': blockId,
        if (type != 'delete_note') 'expected_revision': expectedRevision,
        if (text != null) 'text': text,
        if (evidenceRefs.isNotEmpty)
          'evidence_refs': [for (final ref in evidenceRefs) ref.toJson()],
        if (supersedes.isNotEmpty)
          'supersedes': [for (final ref in supersedes) ref.toJson()],
      };
}

List<EvidenceReference> _references(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List<dynamic>) {
    throw const FormatException('Evidence references must be a list');
  }
  final references = <EvidenceReference>[];
  for (final value in raw) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Evidence reference must be an object');
    }
    references.add(EvidenceReference.fromJson(value));
  }
  return references;
}
