part of '../storage.dart';

extension _TypedGroupPublication on Storage {
  Directory get _typedGroups => Directory('${_historyDir.path}/typed-groups');

  Future<void> _commitTypedGroup(TypedKnowledgeAcceptancePermit permit) async {
    final events = <Map<String, dynamic>>[];
    final desired = <String, String>{};
    final ids = permit.notes.map((note) => note.id).toSet();
    if (ids.length != permit.notes.length || ids.isEmpty) {
      throw StateError('Invalid typed group identities');
    }
    for (final note in permit.notes) {
      final path = _relativeFilePath(path: note.path, title: note.title);
      final key = collisionKey(path);
      if (desired.containsKey(key) && desired[key] != note.id) {
        throw PathConflictException(path: note.path, title: note.title);
      }
      desired[key] = note.id;
      final owner = _idByKey[key];
      if (owner != null && owner != note.id && !ids.contains(owner)) {
        throw PathConflictException(path: note.path, title: note.title);
      }
      final oldPath = _relPathById[note.id];
      StoredNote? previous;
      MarkdownBlockMap? previousMap;
      if (oldPath != null) {
        previous = await read(note.id);
        if (note.version != previous.version + 1 || !permit.matches(previous)) {
          throw VersionConflictException(
            current: previous,
            suppliedIfMatch: note.version - 1,
          );
        }
        await ensureRequiredHistory(note.id);
        previousMap = await readBlockMap(note.id);
      } else if (note.version != 1) {
        throw StateError('Typed create must start at revision one');
      }
      final blockMap = _blockReconciler.reconcile(
        note.content,
        version: note.version,
        previous: previousMap,
        previousSource: previous?.content,
      );
      final updates = <Map<String, dynamic>>[];
      for (final record in await proposalRecords(noteId: note.id)) {
        if (record.id == permit.record.id) continue;
        final invalidated = record.invalidate(
          reason: 'accepted_target_changed',
          at: _clock.nowUtc(),
        );
        if (!identical(record, invalidated)) {
          updates.add(invalidated.toStoredJson());
        }
      }
      events.add({
        'id': note.id,
        'version': note.version,
        'deleted': false,
        'actor': permit.record.events.lastWhere(
          (event) => const {'approve', 'auto_approve'}.contains(event['type']),
        )['author_label'],
        'recorded_at': _clock.nowUtc().toIso8601String(),
        'markdown': _serializeNote(note),
        'block_map': blockMap.toJson(),
        'accepted_provenance': {'typed_proposal': permit.record.id},
        if (permit.policyDeltas.containsKey(note.id))
          'accepted_policy_delta': permit.policyDeltas[note.id],
        'proposal_updates': updates,
        'path': path,
        'previous_path': oldPath,
      });
    }
    final journal = File('${_typedGroups.path}/${permit.record.id}.json');
    if (journal.existsSync()) {
      throw StateError('Typed publication requires recovery');
    }
    await _atomicText(
      journal,
      jsonEncode({'events': events, 'record': permit.record.toStoredJson()}),
    );
    await beforeHistoryApply?.call();
    await _applyTypedGroup(
      jsonDecode(await journal.readAsString()) as Map<String, dynamic>,
      injectFailure: true,
    );
    await journal.delete();
    for (final note in permit.notes) {
      final old = _relPathById.remove(note.id);
      if (old != null) _idByKey.remove(collisionKey(old));
    }
    for (final note in permit.notes) {
      final path = _relativeFilePath(path: note.path, title: note.title);
      _claim(id: note.id, key: collisionKey(path), relPath: path);
    }
  }

  Future<void> _applyTypedGroup(
    Map<String, dynamic> journal, {
    bool injectFailure = false,
  }) async {
    final events =
        (journal['events'] as List<dynamic>).cast<Map<String, dynamic>>();
    final targets = events.map((event) => event['path'] as String).toSet();
    for (final event in events) {
      final previous = event['previous_path'] as String?;
      if (previous != null && !targets.contains(previous)) {
        final file = _fileForRelative(previous);
        if (file.existsSync()) await file.delete();
      }
    }
    for (final event in events) {
      final id = event['id'] as String;
      await _atomicText(_historyIndexTicket(id, event['version'] as int), '');
      await _applyHistory(
        _noteHistory(id),
        {...event, 'previous_path': null},
        injectFailure: injectFailure,
      );
    }
    final record = ProposalRecord.fromStoredJson(
      journal['record'] as Map<String, dynamic>,
    );
    if (record.state != 'accepted') {
      throw const FormatException(
        'Typed journal lacks accepted review outcome',
      );
    }
    await _atomicText(
      _proposalFile(record.noteId, record.id),
      jsonEncode(record.toStoredJson()),
    );
  }

  Future<void> _applyTypedProposalIntent(Map<String, dynamic> intent) async {
    final record =
        ProposalRecord.fromStoredJson(intent['record'] as Map<String, dynamic>);
    if (record.state != 'pending') {
      throw const FormatException('Invalid proposal intent state');
    }
    final file = _proposalFile(record.noteId, record.id);
    if (file.existsSync()) {
      final previous = ProposalRecord.fromStoredJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      if (previous.recordRevision != record.recordRevision) {
        if (previous.recordRevision != intent['expected_record_revision']) {
          throw const ProposalRecordConflictException('record_changed');
        }
        await _atomicText(file, jsonEncode(record.toStoredJson()));
      } else if (jsonEncode(previous.toStoredJson()) !=
          jsonEncode(record.toStoredJson())) {
        throw const ProposalRecordConflictException('record_changed');
      }
    } else {
      if (intent['expected_record_revision'] != null) {
        throw const ProposalRecordConflictException('record_changed');
      }
      await _atomicText(file, jsonEncode(record.toStoredJson()));
    }
    final key = intent['key'] as String;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const FormatException('Invalid receipt identity');
    }
    await _atomicText(
      File('${_historyDir.path}/typed-receipts/$key.json'),
      jsonEncode(intent['receipt']),
    );
  }

  Future<void> _recoverTypedProposalIntents() async {
    final intents = Directory('${_historyDir.path}/typed-intents');
    if (!intents.existsSync()) return;
    await for (final entity in intents.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      await _applyTypedProposalIntent(
        jsonDecode(await entity.readAsString()) as Map<String, dynamic>,
      );
      await entity.delete();
    }
  }

  Future<void> _recoverTypedGroups() async {
    if (!_typedGroups.existsSync()) return;
    await for (final entity in _typedGroups.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      await _applyTypedGroup(
        jsonDecode(await entity.readAsString()) as Map<String, dynamic>,
      );
      await entity.delete();
    }
  }
}
