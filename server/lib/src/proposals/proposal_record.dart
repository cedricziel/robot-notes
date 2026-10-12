import 'dart:convert';

/// Recorded credential identity is audit data, never decision authority.
class ProposalAuthor {
  /// Captures identity and display data from the authenticated context.
  const ProposalAuthor({
    required this.principalId,
    required this.label,
    required this.kind,
    this.agentOrigin = false,
  });

  /// Restores server-recorded identity without granting capabilities.
  factory ProposalAuthor.fromJson(Map<String, dynamic> json) => ProposalAuthor(
        principalId: json['principal_id'] as String,
        label: json['label'] as String,
        kind: json['kind'] as String,
        agentOrigin: json['agent_origin'] as bool? ?? false,
      );

  /// Stable server credential identity.
  final String principalId;

  /// Human-readable attribution; labels never authorize actions.
  final String label;

  /// Recorded operator, agent, or OAuth credential kind.
  final String kind;

  /// Restrictive agent origin recorded by the authenticated transport.
  final bool agentOrigin;

  /// Serializes audit identity for durable storage.
  Map<String, dynamic> toJson() => {
        'principal_id': principalId,
        'label': label,
        'kind': kind,
        'agent_origin': agentOrigin,
      };
}

/// A retained candidate version is immutable even when the proposal is amended.
class ProposalVersion {
  /// Freezes candidate input as an exact JSON value.
  ProposalVersion({
    required this.revision,
    required this.author,
    required this.createdAt,
    required Map<String, dynamic> candidate,
  }) : _candidate = jsonEncode(candidate);

  /// Restores one immutable candidate snapshot.
  factory ProposalVersion.fromJson(Map<String, dynamic> json) =>
      ProposalVersion(
        revision: json['proposal_revision'] as int,
        author: ProposalAuthor.fromJson(json['author'] as Map<String, dynamic>),
        createdAt: DateTime.parse(json['created_at'] as String),
        candidate: json['candidate'] as Map<String, dynamic>,
      );

  /// Candidate revision within this proposal.
  final int revision;

  /// Authenticated author of this particular amendment.
  final ProposalAuthor author;

  /// Server timestamp for this candidate.
  final DateTime createdAt;
  final String _candidate;

  /// Returns a copy so callers cannot modify retained candidate history.
  Map<String, dynamic> get candidate =>
      jsonDecode(_candidate) as Map<String, dynamic>;

  /// Serializes a retained candidate version.
  Map<String, dynamic> toJson() => {
        'proposal_revision': revision,
        'author': author.toJson(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'candidate': candidate,
      };
}

/// An outdated record or terminal proposal cannot be changed by a stale client.
class ProposalRecordConflictException implements Exception {
  /// Names the failed optimistic concurrency or state precondition.
  const ProposalRecordConflictException(this.reason);

  /// Machine-readable conflict reason.
  final String reason;
}

/// Versioned pending knowledge and immutable review activity.
class ProposalRecord {
  ProposalRecord._({
    required this.id,
    required this.noteId,
    required this.author,
    required this.recordRevision,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required List<ProposalVersion> versions,
    required List<Map<String, dynamic>> events,
    this.acceptedVersion,
  })  : versions = List.unmodifiable(versions),
        _events = jsonEncode(events);

  /// Creates pending review data, without any accepted document mutation.
  factory ProposalRecord.create({
    required String id,
    required String noteId,
    required ProposalAuthor author,
    required DateTime at,
    required Map<String, dynamic> candidate,
  }) =>
      ProposalRecord._(
        id: id,
        noteId: noteId,
        author: author,
        recordRevision: 1,
        state: 'pending',
        createdAt: at,
        updatedAt: at,
        versions: [
          ProposalVersion(
            revision: 1,
            author: author,
            createdAt: at,
            candidate: candidate,
          ),
        ],
        events: [_event('submitted', author, at, 1)],
      );

  /// Restores server-owned review state; never use this for caller submissions.
  factory ProposalRecord.fromStoredJson(Map<String, dynamic> json) {
    if (json['format_version'] != 1 || !_states.contains(json['state'])) {
      throw const FormatException('Invalid proposal record format');
    }
    final versions = [
      for (final version in json['versions'] as List<dynamic>)
        ProposalVersion.fromJson(version as Map<String, dynamic>),
    ];
    if (versions.isEmpty ||
        json['record_revision'] is! int ||
        (json['record_revision'] as int) < versions.last.revision ||
        versions.indexed.any((entry) => entry.$2.revision != entry.$1 + 1) ||
        json['proposal_revision'] != versions.last.revision ||
        (json['state'] == 'accepted') != (json['accepted_version'] != null) ||
        (json['accepted_version'] != null &&
            (json['accepted_version'] is! int ||
                (json['accepted_version'] as int) < 1))) {
      throw const FormatException('Invalid proposal revisions');
    }
    return ProposalRecord._(
      id: json['proposal_id'] as String,
      noteId: json['note_id'] as String,
      author: ProposalAuthor.fromJson(json['author'] as Map<String, dynamic>),
      recordRevision: json['record_revision'] as int,
      state: json['state'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      versions: versions,
      events: (json['events'] as List<dynamic>).cast<Map<String, dynamic>>(),
      acceptedVersion: json['accepted_version'] as int?,
    );
  }

  static const _states = {
    'pending',
    'changes_requested',
    'needs_re_review',
    'conflicted',
    'accepted',
    'denied',
  };

  /// Opaque proposal identity.
  final String id;

  /// Accepted or server-reserved note identity.
  final String noteId;

  /// Initial authenticated proposer, retained across later amendments.
  final ProposalAuthor author;

  /// Envelope generation for all optimistic activity updates.
  final int recordRevision;

  /// Current review state, independent of accepted note content.
  final String state;

  /// Server creation time.
  final DateTime createdAt;

  /// Server time of the latest activity update.
  final DateTime updatedAt;

  /// Immutable candidate history, oldest first.
  final List<ProposalVersion> versions;

  /// Accepted note version, populated only in journal publication records.
  final int? acceptedVersion;
  final String _events;

  /// Latest immutable candidate.
  ProposalVersion get current => versions.last;

  /// Current candidate generation, distinct from concurrent review activity.
  int get proposalRevision => current.revision;

  /// Copies immutable activity so caller mutation cannot alter stored history.
  List<Map<String, dynamic>> get events =>
      (jsonDecode(_events) as List<dynamic>).cast<Map<String, dynamic>>();

  /// Thread comments remain inspectable across candidate changes.
  List<Map<String, dynamic>> get comments =>
      events.where((e) => e['type'] == 'comment').toList();

  void _check(int revision, {bool allowTerminal = false}) {
    if (revision != recordRevision) {
      throw const ProposalRecordConflictException('record_changed');
    }
    if (!allowTerminal && const {'accepted', 'denied'}.contains(state)) {
      throw const ProposalRecordConflictException('proposal_terminal');
    }
  }

  /// Retains the old candidate and resets prior review after a valid amendment.
  ProposalRecord amend({
    required int expectedRecordRevision,
    required int expectedProposalRevision,
    required ProposalAuthor author,
    required DateTime at,
    required Map<String, dynamic> candidate,
  }) {
    _check(expectedRecordRevision);
    if (expectedProposalRevision != proposalRevision) {
      throw const ProposalRecordConflictException('candidate_changed');
    }
    return _next(
      at,
      'pending',
      [...events, _event('amended', author, at, proposalRevision + 1)],
      versions: [
        ...versions,
        ProposalVersion(
          revision: proposalRevision + 1,
          author: author,
          createdAt: at,
          candidate: candidate,
        ),
      ],
    );
  }

  /// Appends a thread event under the latest record generation.
  ProposalRecord comment({
    required int expectedRecordRevision,
    required ProposalAuthor author,
    required String body,
    required DateTime at,
    required String commentId,
    String? blockId,
    int? blockRevision,
    String? replyTo,
    int? noteVersion,
    String? anchorKind,
  }) {
    _check(expectedRecordRevision, allowTerminal: true);
    if (body.trim().isEmpty || (blockId == null) != (blockRevision == null)) {
      throw const FormatException('Invalid comment body or anchor');
    }
    Map<String, dynamic>? parent;
    if (replyTo != null) {
      final matches = comments.where((e) => e['comment_id'] == replyTo);
      if (matches.isEmpty) {
        throw const FormatException('Comment thread not found');
      }
      parent = matches.single;
      if (blockId != null &&
          (blockId != parent['block_id'] ||
              blockRevision != parent['block_revision'])) {
        throw const FormatException('Reply cannot change its thread anchor');
      }
    }
    final event = _event('comment', author, at, proposalRevision)
      ..addAll({
        'comment_id': commentId,
        'thread_id': parent?['thread_id'] ?? commentId,
        'body': body,
        if (replyTo != null) 'reply_to': replyTo,
        if (anchorKind != null || parent?['anchor_kind'] != null)
          'anchor_kind': parent?['anchor_kind'] ?? anchorKind,
        if (noteVersion != null || parent?['note_version'] != null)
          'note_version': parent?['note_version'] ?? noteVersion,
        if (blockId != null || parent?['block_id'] != null)
          'block_id': blockId ?? parent!['block_id'],
        if (blockRevision != null || parent?['block_revision'] != null)
          'block_revision': blockRevision ?? parent!['block_revision'],
      });
    return _next(at, state, [...events, event]);
  }

  /// Records non-accepting decisions; authority must be checked by the service.
  ProposalRecord decide({
    required int expectedRecordRevision,
    required ProposalAuthor author,
    required String decision,
    required DateTime at,
  }) {
    _check(expectedRecordRevision);
    if (!const {'deny', 'request_changes'}.contains(decision)) {
      throw ArgumentError('Approval requires an accepted journal outcome');
    }
    return _next(
      at,
      decision == 'deny' ? 'denied' : 'changes_requested',
      [...events, _event(decision, author, at, proposalRevision)],
    );
  }

  /// Prepares final metadata for a verified acceptance journal.
  ProposalRecord acceptedForJournal({
    required int expectedRecordRevision,
    required ProposalAuthor reviewer,
    required DateTime at,
    required int noteVersion,
    bool automatic = false,
  }) {
    _check(expectedRecordRevision);
    if (!const {'pending', 'changes_requested'}.contains(state) ||
        noteVersion < 1) {
      throw const ProposalRecordConflictException('review_not_current');
    }
    return _next(
      at,
      'accepted',
      [
        ...events,
        _event(
          automatic ? 'auto_approve' : 'approve',
          reviewer,
          at,
          proposalRevision,
        ),
        if (automatic)
          {
            'type': 'eligibility_verified',
            'eligibility': 'source_attachment_only',
            'proposal_revision': proposalRevision,
            'created_at': at.toUtc().toIso8601String(),
          },
      ],
      acceptedVersion: noteVersion,
    );
  }

  /// Invalidates stale pending review while retaining its audit.
  ProposalRecord invalidate({
    required String reason,
    required DateTime at,
    bool conflicted = false,
  }) {
    if (const {'accepted', 'denied'}.contains(state)) return this;
    return _next(
      at,
      conflicted ? 'conflicted' : 'needs_re_review',
      [
        ...events,
        {
          'type': 'invalidated',
          'reason': reason,
          'proposal_revision': proposalRevision,
          'created_at': at.toUtc().toIso8601String(),
        }
      ],
    );
  }

  ProposalRecord _next(
    DateTime at,
    String nextState,
    List<Map<String, dynamic>> nextEvents, {
    List<ProposalVersion>? versions,
    int? acceptedVersion,
  }) =>
      ProposalRecord._(
        id: id,
        noteId: noteId,
        author: author,
        recordRevision: recordRevision + 1,
        state: nextState,
        createdAt: createdAt,
        updatedAt: at,
        versions: versions ?? this.versions,
        events: nextEvents,
        acceptedVersion: acceptedVersion ?? this.acceptedVersion,
      );

  /// Lists review activity without copying candidate bodies into normal recall.
  Map<String, dynamic> summary() => {
        'proposal_id': id,
        'note_id': noteId,
        'state': state,
        'accepted': state == 'accepted',
        'proposal_revision': proposalRevision,
        'record_revision': recordRevision,
        'author_label': author.label,
        'author_kind': author.kind,
        'author_agent_origin': author.agentOrigin,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        if (acceptedVersion != null) 'accepted_version': acceptedVersion,
      };

  /// Includes candidate context and retained activity for explicit inspection.
  Map<String, dynamic> inspect() => {
        ...current.candidate,
        ...summary(),
        'comments': comments,
        'events': events,
      };

  /// Serializes durable candidate and audit data outside canonical Markdown.
  Map<String, dynamic> toStoredJson() => {
        'format_version': 1,
        ...summary(),
        'author': author.toJson(),
        'versions': [for (final version in versions) version.toJson()],
        'events': events,
      };
}

Map<String, dynamic> _event(
  String type,
  ProposalAuthor author,
  DateTime at,
  int proposalRevision,
) =>
    {
      'type': type,
      'author_principal_id': author.principalId,
      'author_label': author.label,
      'author_kind': author.kind,
      'author_agent_origin': author.agentOrigin,
      'proposal_revision': proposalRevision,
      'created_at': at.toUtc().toIso8601String(),
    };
