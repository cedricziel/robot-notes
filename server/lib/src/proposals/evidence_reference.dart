/// A typed source reference, never a caller claim of truth or authorization.
class EvidenceReference {
  EvidenceReference._(Map<String, Object?> fields)
      : _fields = Map.unmodifiable(fields);

  /// Rejects authority flags, cross-vault overrides, and malformed coordinates.
  factory EvidenceReference.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final requiredStrings = switch (kind) {
      'note_revision' => const ['note_id'],
      'block_revision' => const ['note_id', 'block_id'],
      'archive' => const ['digest'],
      'conversation' => const ['session_id'],
      'url' => const ['url'],
      'unknown' => const ['reason'],
      _ => throw const FormatException('Unknown evidence reference kind'),
    };
    final requiredIntegers = switch (kind) {
      'note_revision' => const ['version'],
      'block_revision' => const ['version', 'block_revision'],
      _ => const <String>[],
    };
    final optionalStrings = kind == 'conversation'
        ? const ['turn_id', 'tool_call_id', 'task_id']
        : const <String>[];
    final allowed = [
      'kind',
      ...requiredStrings,
      ...requiredIntegers,
      ...optionalStrings,
    ];
    if (!json.keys.every(allowed.contains)) {
      throw const FormatException('Unsupported evidence reference field');
    }
    for (final name in requiredStrings) {
      if (json[name] is! String || (json[name] as String).trim().isEmpty) {
        throw FormatException('Evidence $name must be a non-empty string');
      }
    }
    for (final name in requiredIntegers) {
      if (json[name] is! int || (json[name] as int) < 1) {
        throw FormatException('Evidence $name must be a positive integer');
      }
    }
    for (final name in optionalStrings) {
      if (json.containsKey(name) &&
          (json[name] is! String || (json[name] as String).trim().isEmpty)) {
        throw FormatException('Evidence $name must be a non-empty string');
      }
    }
    if (kind == 'archive' &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['digest'] as String)) {
      throw const FormatException('Archive digest must be lowercase SHA-256');
    }
    if (kind == 'url') {
      final uri = Uri.tryParse(json['url'] as String);
      if (uri == null ||
          !const {'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw const FormatException('Evidence URL must be absolute HTTP(S)');
      }
    }
    return EvidenceReference._({
      for (final name in allowed)
        if (json.containsKey(name)) name: json[name] as Object?,
    });
  }

  final Map<String, Object?> _fields;

  /// Wire source type; unverified lineage stays distinct from stored evidence.
  String get kind => _fields['kind']! as String;

  /// Referenced accepted source note in the authenticated selected vault.
  String? get noteId => _fields['note_id'] as String?;

  /// Exact retained accepted note revision.
  int? get noteVersion => _fields['version'] as int?;

  /// Opaque accepted block identity when a precise block is referenced.
  String? get blockId => _fields['block_id'] as String?;

  /// Exact accepted block revision, independent of whole-note version.
  int? get blockRevision => _fields['block_revision'] as int?;

  /// Explicit archive lookup digest; existence does not prove claim truth.
  String? get digest => _fields['digest'] as String?;

  /// Whether an immutable storage resolver exists for this source type.
  /// Read access is still required. Resolution cannot prove claim consistency.
  bool get requiresResolution =>
      const {'note_revision', 'block_revision', 'archive'}.contains(kind);

  /// Serializes reference coordinates without manufacturing proof metadata.
  Map<String, Object?> toJson() => {..._fields};
}
