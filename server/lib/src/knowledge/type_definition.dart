import 'dart:convert';

/// Immutable identity of an accepted type revision.
class KnowledgeTypeReference {
  /// Rejects empty identities and unpinned versions.
  KnowledgeTypeReference(this.id, this.version) {
    if (id.trim().isEmpty ||
        !((version is int && (version! as int) > 0) ||
            (version is String && (version! as String).trim().isNotEmpty))) {
      throw const FormatException('Invalid pinned type reference');
    }
  }

  /// Decodes the stable identity and version fields.
  factory KnowledgeTypeReference.fromJson(Object? value) {
    final map = _map(value);
    return KnowledgeTypeReference(_text(map['id']), map['version']);
  }

  /// Stable namespaced type identity.
  final String id;

  /// Exact integer or release identifier retained by the parent snapshot.
  final Object? version;

  /// Collision-free key preserving version value types.
  String get key => jsonEncode([id, version]);

  /// Portable pinned reference.
  Map<String, Object?> toJson() => {'id': id, 'version': version};
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected object');
  }
  return value;
}

String _text(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Expected nonempty text');
  }
  return value;
}

List<Object?> _list(Object? value) {
  if (value is! List<Object?>) throw const FormatException('Expected list');
  return value;
}

void _bounds(Map<String, Object?> value) {
  for (final key in ['min_items', 'max_items']) {
    if (value.containsKey(key) &&
        (value[key] is! int || (value[key]! as int) < 0)) {
      throw const FormatException('Invalid cardinality');
    }
  }
  if ((value['min_items'] as int? ?? 0) >
      (value['max_items'] as int? ?? 0x7fffffff)) {
    throw const FormatException('Inverted cardinality');
  }
}

void _property(Map<String, Object?> value) {
  if (!value.keys.every(
    const {
      'value_type',
      'required',
      'enum',
      'items',
      'min_items',
      'max_items',
    }.contains,
  )) {
    throw const FormatException('Unsupported property constraint');
  }
  if (!const {'text', 'number', 'boolean', 'date', 'list'}
      .contains(value['value_type'])) {
    throw const FormatException('Unsupported property value_type');
  }
  if (value.containsKey('required') && value['required'] is! bool) {
    throw const FormatException('Invalid required flag');
  }
  _bounds(value);
  if (value['value_type'] == 'list') {
    final items = _map(value['items']);
    _property(items);
    if (items['value_type'] == 'list') {
      throw const FormatException('Nested lists unsupported');
    }
  } else if (value.containsKey('items') ||
      value.containsKey('min_items') ||
      value.containsKey('max_items')) {
    throw const FormatException('Cardinality requires list property');
  }
  if (value.containsKey('enum')) {
    final options = _list(value['enum']);
    if (options.isEmpty ||
        options.any((item) => !_matches(value, item, checkEnum: false))) {
      throw const FormatException('Invalid enum');
    }
  }
}

bool _matches(
  Map<String, Object?> constraint,
  Object? value, {
  bool checkEnum = true,
}) {
  final valid = switch (constraint['value_type']) {
    'text' => value is String &&
        (constraint['required'] != true || value.trim().isNotEmpty),
    'number' => value is num && value.isFinite,
    'boolean' => value is bool,
    'date' => value is String &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) &&
        DateTime.tryParse(value)?.toIso8601String().substring(0, 10) == value,
    'list' => value is List<Object?> &&
        value.length >= (constraint['min_items'] as int? ?? 0) &&
        value.length <= (constraint['max_items'] as int? ?? 0x7fffffff) &&
        value.every((item) => _matches(_map(constraint['items']), item)),
    _ => false,
  };
  return valid &&
      (!checkEnum ||
          !constraint.containsKey('enum') ||
          _list(constraint['enum']).contains(value));
}

/// Version-one type metadata, separate from database discriminators.
class KnowledgeTypeDefinition {
  KnowledgeTypeDefinition._(this._metadata);

  /// Validates the supported constraint language before accepting a definition.
  factory KnowledgeTypeDefinition.fromMetadata(Object? value) {
    final metadata = _map(value);
    if (metadata['format_version'] is! int ||
        metadata['format_version'] != 1 ||
        metadata['role'] != 'type_definition') {
      throw const FormatException('Unsupported knowledge type format');
    }
    final definition = _map(metadata['definition']);
    KnowledgeTypeReference.fromJson(definition);
    for (final parent in _list(definition['extends'] ?? const <Object?>[])) {
      KnowledgeTypeReference.fromJson(parent);
    }
    for (final entry
        in _map(definition['properties'] ?? const <String, Object?>{})
            .entries) {
      _text(entry.key);
      if (const {
        'id',
        'title',
        'version',
        'path',
        'created_at',
        'updated_at',
        'knowledge',
        'type',
      }.contains(entry.key)) {
        throw const FormatException('Reserved property name');
      }
      _property(_map(entry.value));
    }
    for (final entry
        in _map(definition['relations'] ?? const <String, Object?>{}).entries) {
      _text(entry.key);
      final relation = _map(entry.value);
      if (!relation.keys
          .every(const {'target_types', 'min_items', 'max_items'}.contains)) {
        throw const FormatException('Unsupported relation constraint');
      }
      _bounds(relation);
      final targets = _list(relation['target_types']);
      if (targets.isEmpty) {
        throw const FormatException('Relation needs target types');
      }
      for (final target in targets) {
        KnowledgeTypeReference.fromJson(target);
      }
    }
    if (definition.containsKey('guidance')) _map(definition['guidance']);
    return KnowledgeTypeDefinition._(
      jsonDecode(jsonEncode(metadata)) as Map<String, Object?>,
    );
  }

  final Map<String, Object?> _metadata;
  Map<String, Object?> get _definition => _map(_metadata['definition']);

  /// Stable definition identity, independent of its filesystem path.
  String get id => _definition['id']! as String;

  /// Exact revision used by entries and child definitions.
  KnowledgeTypeReference get reference =>
      KnowledgeTypeReference.fromJson(_definition);

  /// Pinned parent definitions in declared order.
  List<KnowledgeTypeReference> get parents =>
      _list(_definition['extends'] ?? const <Object?>[])
          .map(KnowledgeTypeReference.fromJson)
          .toList();

  /// Defensive copy of enforced property constraints.
  Map<String, Object?> get properties =>
      _map(toMetadata()['definition'])['properties'] as Map<String, Object?>? ??
      {};

  /// Defensive copy of enforced relation constraints.
  Map<String, Object?> get relations =>
      _map(toMetadata()['definition'])['relations'] as Map<String, Object?>? ??
      {};

  /// Portable metadata preserving descriptions, guidance, and origin.
  Map<String, Object?> toMetadata() =>
      jsonDecode(jsonEncode(_metadata)) as Map<String, Object?>;

  /// Returns property diagnostics; structural validity does not establish
  /// truth.
  List<String> validateProperties(Map<String, Object?> values) {
    final diagnostics = <String>[];
    for (final entry in properties.entries) {
      final constraint = _map(entry.value);
      if (!values.containsKey(entry.key)) {
        if (constraint['required'] == true) {
          diagnostics.add('${entry.key}: required');
        }
      } else if (!_matches(constraint, values[entry.key])) {
        diagnostics.add('${entry.key}: invalid value');
      }
    }
    return diagnostics;
  }
}

/// Resolves only supplied pinned snapshots, without network lookup.
class KnowledgeTypeResolver {
  /// Builds an offline registry and rejects duplicate pinned identities.
  KnowledgeTypeResolver(Iterable<KnowledgeTypeDefinition> definitions) {
    for (final definition in definitions) {
      if (_definitions.containsKey(definition.reference.key)) {
        throw const FormatException('Duplicate type revision');
      }
      _definitions[definition.reference.key] = definition;
    }
  }

  final _definitions = <String, KnowledgeTypeDefinition>{};

  /// Rejects unresolved parents, cycles, or incompatible inherited constraints.
  KnowledgeTypeDefinition resolve(KnowledgeTypeReference reference) =>
      _resolve(reference, {});

  KnowledgeTypeDefinition _resolve(
    KnowledgeTypeReference reference,
    Set<String> visiting,
  ) {
    if (!visiting.add(reference.key)) {
      throw const FormatException('Type inheritance cycle');
    }
    final current = _definitions[reference.key];
    if (current == null) {
      throw const FormatException('Missing pinned type revision');
    }
    final properties = <String, Object?>{};
    final relations = <String, Object?>{};
    for (final parent in current.parents) {
      final resolved = _resolve(parent, {...visiting});
      _merge(properties, resolved.properties, inherited: true);
      _merge(relations, resolved.relations, inherited: true);
    }
    _merge(properties, current.properties);
    _merge(relations, current.relations);
    final metadata = current.toMetadata();
    _map(metadata['definition'])
        .addAll({'properties': properties, 'relations': relations});
    return KnowledgeTypeDefinition.fromMetadata(metadata);
  }

  /// Validates named relations against pinned types of authorized targets.
  List<String> validateRelations(
    KnowledgeTypeReference type,
    Map<String, Object?> values,
    Map<String, List<KnowledgeTypeReference>> targetTypes,
  ) {
    final definition = resolve(type);
    final diagnostics = <String>[];
    for (final name in values.keys) {
      if (!definition.relations.containsKey(name)) {
        diagnostics.add('$name: undeclared relation');
      }
    }
    for (final entry in definition.relations.entries) {
      final constraint = _map(entry.value);
      final targets = values[entry.key] ?? const <Object?>[];
      if (targets is! List<Object?> ||
          targets.any((target) => target is! String || target.isEmpty) ||
          targets.toSet().length != targets.length) {
        diagnostics.add('${entry.key}: invalid target list');
        continue;
      }
      if (targets.length < (constraint['min_items'] as int? ?? 0) ||
          targets.length > (constraint['max_items'] as int? ?? 0x7fffffff)) {
        diagnostics.add('${entry.key}: invalid cardinality');
      }
      final allowed = _list(constraint['target_types'])
          .map(KnowledgeTypeReference.fromJson)
          .toList();
      for (final target in targets) {
        final assigned = targetTypes[target! as String];
        if (assigned == null ||
            !assigned.any(
              (actual) =>
                  allowed.any((expected) => _isSubtype(actual, expected)),
            )) {
          diagnostics.add('${entry.key}: unresolved or incompatible target');
        }
      }
    }
    return diagnostics;
  }

  /// Checks compatibility through accepted pinned parent definitions.
  bool isSubtype(
    KnowledgeTypeReference actual,
    KnowledgeTypeReference expected,
  ) =>
      _isSubtype(actual, expected);

  bool _isSubtype(
    KnowledgeTypeReference actual,
    KnowledgeTypeReference expected,
  ) {
    final definition = resolve(actual);
    return actual.key == expected.key ||
        definition.parents.any((parent) => _isSubtype(parent, expected));
  }

  void _merge(
    Map<String, Object?> target,
    Map<String, Object?> incoming, {
    bool inherited = false,
  }) {
    for (final entry in incoming.entries) {
      final previous = target[entry.key];
      if (previous == null) {
        target[entry.key] = entry.value;
        continue;
      }
      final left = _map(previous);
      final right = _map(entry.value);
      if (inherited && jsonEncode(left) != jsonEncode(right)) {
        throw const FormatException('Conflicting inherited constraints');
      }
      if (left['value_type'] != right['value_type'] ||
          (left['required'] == true && right['required'] != true) ||
          (right['min_items'] as int? ?? 0) <
              (left['min_items'] as int? ?? 0) ||
          (right['max_items'] as int? ?? 0x7fffffff) >
              (left['max_items'] as int? ?? 0x7fffffff)) {
        throw const FormatException('Child weakens inherited constraint');
      }
      if (left.containsKey('enum') &&
          (!right.containsKey('enum') ||
              !_list(right['enum']).every(_list(left['enum']).contains))) {
        throw const FormatException('Child widens inherited enum');
      }
      if (left.containsKey('items') &&
          jsonEncode(left['items']) != jsonEncode(right['items'])) {
        throw const FormatException('Conflicting list item constraints');
      }
      if (left.containsKey('target_types')) {
        final allowed = _list(left['target_types'])
            .map((item) => KnowledgeTypeReference.fromJson(item).key)
            .toSet();
        if (!_list(right['target_types']).every(
          (item) => allowed.contains(KnowledgeTypeReference.fromJson(item).key),
        )) {
          throw const FormatException('Child widens relation targets');
        }
      }
      target[entry.key] = entry.value;
    }
  }
}
