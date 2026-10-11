part of 'proposal_service.dart';

/// Unforgeable publication authority issued by the authorized review service.
class ProposalAcceptancePermit {
  ProposalAcceptancePermit._({
    required this.storage,
    required this.record,
    required this.note,
    required this.blockMap,
    required this.provenance,
    required this.deleted,
    required this.newNote,
    required this.actor,
    this.policyDelta,
  });

  /// Source store selected by the authenticated request.
  final Storage storage;

  /// Final accepted record; only the accepted journal may persist it.
  final ProposalRecord record;

  /// Exact next canonical state, or prior state for a deletion tombstone.
  final StoredNote note;

  /// Server-compiled accepted identities.
  final MarkdownBlockMap blockMap;

  /// Accepted source associations, separate from canonical content.
  final Map<String, dynamic> provenance;

  /// True only for whole-note deletion.
  final bool deleted;

  /// True only for a reserved note draft.
  final bool newNote;

  /// Reviewer display attribution; never used to authorize publication.
  final String actor;

  /// Minimal server-authorized note designation for journal replay.
  final Map<String, dynamic>? policyDelta;
  bool _active = true;
  bool _claimed = false;

  /// Allows the selected storage to consume this permit once while in review.
  void claim(Storage target) {
    if (!_active || _claimed || !identical(target, storage)) {
      throw StateError('Invalid or expired proposal acceptance permit');
    }
    _claimed = true;
  }
}
