import 'package:meta/meta.dart';
import 'package:server/src/storage.dart';
import 'package:shared/shared.dart';

/// Frontmatter keys reserved by the note schema itself (`id`, `version`,
/// ...) or used by a definition note (`type`, `source`, `properties`,
/// `views`). Neither may be declared as a property key, nor written as a
/// property value on any typed write, per the `databases` spec's "Property
/// definitions have a key, a type, and type-specific options" requirement.
const Set<String> kReservedPropertyKeys = {
  'id',
  'title',
  'path',
  'version',
  'created_at',
  'updated_at',
  'type',
  'tags',
  'source',
  'properties',
  'views',
};

/// Built-in fields that behave as read-only properties: usable in a
/// filter/sort/`group_by`, but never a target of a typed write (they are
/// also members of [kReservedPropertyKeys], listed separately here because
/// callers reason about them for a different purpose — filter/sort
/// applicability rather than write rejection).
const Set<String> kBuiltinKeys = {
  'title',
  'path',
  'tags',
  'created_at',
  'updated_at'
};

/// Property key pattern per spec: lowercase ASCII, starting with a letter,
/// letters/digits/underscore only.
final RegExp kPropertyKeyPattern = RegExp(r'^[a-z][a-z0-9_]*$');

/// Maximum property key length per spec.
const int kMaxPropertyKeyLength = 64;

final RegExp _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// A single relation-list entry `[[Title]]` or `[[Title|Alias]]`, matched
/// end-to-end (the whole string is exactly one wikilink, no surrounding
/// text) — the encoding rule for a `relation` property value.
final RegExp _wholeWikilink = RegExp(r'^\[\[(.+?)\]\]$');

/// One structural problem with a [DatabaseDefinition], as found by
/// [validateDefinition]. [path] names the offending location within the
/// definition (e.g. `properties.status.options`, `views[0].group_by`).
@immutable
class DefinitionViolation {
  /// Creates a violation.
  const DefinitionViolation({required this.path, required this.reason});

  /// Dotted/bracketed location of the problem within the definition.
  final String path;

  /// Human-readable reason, suitable for a `validation_failed` message.
  final String reason;

  @override
  String toString() => '$path: $reason';

  @override
  bool operator ==(Object other) =>
      other is DefinitionViolation &&
      other.path == path &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(path, reason);
}

/// One property value that fails its declared type or a reserved-key rule,
/// as found by [validateProperties]. [key] is the property key; [reason]
/// names the database when more than one database declares it.
@immutable
class PropertyViolation {
  /// Creates a violation.
  const PropertyViolation({required this.key, required this.reason});

  /// The property key whose supplied value is invalid.
  final String key;

  /// Human-readable reason, suitable for a `validation_failed` message.
  final String reason;

  @override
  String toString() => '$key: $reason';

  @override
  bool operator ==(Object other) =>
      other is PropertyViolation && other.key == key && other.reason == reason;

  @override
  int get hashCode => Object.hash(key, reason);
}

/// The set of [FilterOp]s applicable to a property of [type], per the
/// `databases` spec's "Filter expressions are structured, not free text"
/// requirement. Shared by definition-level filter validation (view
/// filters) and, in a later group, live query filters.
Set<FilterOp> applicableFilterOps(PropertyType type) {
  switch (type) {
    case PropertyType.text:
    case PropertyType.url:
      return const {
        FilterOp.eq,
        FilterOp.neq,
        FilterOp.contains,
        FilterOp.notContains,
        FilterOp.isEmpty,
        FilterOp.isNotEmpty,
      };
    case PropertyType.number:
    case PropertyType.date:
      return const {
        FilterOp.eq,
        FilterOp.neq,
        FilterOp.gt,
        FilterOp.gte,
        FilterOp.lt,
        FilterOp.lte,
        FilterOp.isEmpty,
        FilterOp.isNotEmpty,
      };
    case PropertyType.checkbox:
    case PropertyType.select:
      return const {
        FilterOp.eq,
        FilterOp.neq,
        FilterOp.isEmpty,
        FilterOp.isNotEmpty,
      };
    case PropertyType.multiSelect:
    case PropertyType.relation:
      return const {
        FilterOp.contains,
        FilterOp.notContains,
        FilterOp.isEmpty,
        FilterOp.isNotEmpty,
      };
  }
}

/// The [PropertyType] a built-in field ([kBuiltinKeys]) behaves as for
/// filter/sort purposes, or `null` if [key] is not a built-in.
PropertyType? builtinPropertyType(String key) {
  switch (key) {
    case 'title':
    case 'path':
      return PropertyType.text;
    case 'tags':
      return PropertyType.multiSelect;
    case 'created_at':
    case 'updated_at':
      return PropertyType.date;
    default:
      return null;
  }
}

/// Validates the structural/semantic rules a [DatabaseDefinition] must
/// satisfy beyond parsing: reserved and malformed property keys, `select`/
/// `multi_select` option rules, view name uniqueness, board `group_by`
/// rules, and that every view filter references a declared property (or a
/// built-in) with an applicable operator. Returns every violation found
/// (never throws); an empty list means the definition is valid.
List<DefinitionViolation> validateDefinition(DatabaseDefinition def) {
  final violations = <DefinitionViolation>[];

  def.properties.forEach((key, prop) {
    final keyPath = 'properties.$key';
    if (kReservedPropertyKeys.contains(key)) {
      violations.add(
        DefinitionViolation(path: keyPath, reason: 'reserved key'),
      );
    } else if (!kPropertyKeyPattern.hasMatch(key) ||
        key.length > kMaxPropertyKeyLength) {
      violations.add(
        DefinitionViolation(
          path: keyPath,
          reason: 'key must match ^[a-z][a-z0-9_]*\$ and be at most '
              '$kMaxPropertyKeyLength characters',
        ),
      );
    }

    if (prop.type == PropertyType.select ||
        prop.type == PropertyType.multiSelect) {
      final options = prop.options;
      if (options == null || options.isEmpty) {
        violations.add(
          DefinitionViolation(
            path: '$keyPath.options',
            reason: 'options is required and must be non-empty for '
                '${prop.type.wire}',
          ),
        );
      } else {
        final seen = <String>{};
        for (final option in options) {
          if (option.isEmpty) {
            violations.add(
              DefinitionViolation(
                path: '$keyPath.options',
                reason: 'option must not be empty',
              ),
            );
          } else if (!seen.add(option)) {
            violations.add(
              DefinitionViolation(
                path: '$keyPath.options',
                reason: 'duplicate option "$option"',
              ),
            );
          }
        }
      }
    }
  });

  final seenViewNames = <String>{};
  for (var i = 0; i < def.views.length; i++) {
    final view = def.views[i];
    final viewPath = 'views[$i]';
    if (view.name.isEmpty) {
      violations.add(
        DefinitionViolation(
            path: '$viewPath.name', reason: 'name must not be empty'),
      );
    } else if (!seenViewNames.add(view.name.toLowerCase())) {
      violations.add(
        DefinitionViolation(
          path: '$viewPath.name',
          reason: 'duplicate view name "${view.name}"',
        ),
      );
    }

    if (view.type == ViewType.board) {
      final groupBy = view.groupBy;
      if (groupBy == null) {
        violations.add(
          DefinitionViolation(
            path: '$viewPath.group_by',
            reason: 'group_by is required for a board view',
          ),
        );
      } else {
        final groupProp = def.properties[groupBy];
        if (groupProp == null || groupProp.type != PropertyType.select) {
          violations.add(
            DefinitionViolation(
              path: '$viewPath.group_by',
              reason: 'group_by must name a select property',
            ),
          );
        }
      }
    }

    final filter = view.filter;
    if (filter != null) {
      _validateFilter(filter, def, violations, '$viewPath.filter');
    }
  }

  return violations;
}

void _validateFilter(
  Filter filter,
  DatabaseDefinition def,
  List<DefinitionViolation> violations,
  String path,
) {
  switch (filter) {
    case Condition condition:
      final declared = def.properties[condition.property];
      final type = declared?.type ?? builtinPropertyType(condition.property);
      if (type == null) {
        violations.add(
          DefinitionViolation(
            path: '$path.property',
            reason: 'undeclared property "${condition.property}"',
          ),
        );
        return;
      }
      if (!applicableFilterOps(type).contains(condition.op)) {
        violations.add(
          DefinitionViolation(
            path: '$path.op',
            reason: '${condition.op.wire} is not applicable to '
                '"${condition.property}"',
          ),
        );
      }
      if ((condition.op == FilterOp.isEmpty ||
              condition.op == FilterOp.isNotEmpty) &&
          condition.value != null) {
        violations.add(
          DefinitionViolation(
            path: '$path.value',
            reason: '${condition.op.wire} takes no value',
          ),
        );
      }
    case And(and: final children):
      for (var i = 0; i < children.length; i++) {
        _validateFilter(children[i], def, violations, '$path.and[$i]');
      }
    case Or(or: final children):
      for (var i = 0; i < children.length; i++) {
        _validateFilter(children[i], def, violations, '$path.or[$i]');
      }
  }
}

/// Validates caller-supplied [properties] against every definition in
/// [covering] (the databases whose source covers the note being written —
/// see `coveringDatabases` in `shared`), per the `databases` spec's
/// "Property values are encoded per type in row frontmatter" requirement.
///
/// [resolveTitle] and [isRowOf] are injected so this stays a pure function
/// of its arguments: [resolveTitle] looks a wikilink target title up (as
/// [NoteSummary], or `null` if it doesn't resolve — an unresolved title is
/// accepted, matching how a dangling body wikilink is tolerated) and
/// [isRowOf] answers whether a resolved note is a row of a given database
/// id. Both are required only to validate a `relation` property that
/// declares a `database` constraint; every other property type ignores
/// them, so tests and callers that never touch relations may omit both.
///
/// A `null` value means "unset" and is never a violation. A key not
/// declared by any definition in [covering] is free-form frontmatter and is
/// never a violation. A key declared by more than one covering definition
/// is validated against every one of them.
List<PropertyViolation> validateProperties(
  List<DatabaseDefinition> covering,
  Map<String, Object?> properties, {
  NoteSummary? Function(String title)? resolveTitle,
  bool Function(NoteSummary note, String databaseId)? isRowOf,
}) {
  final violations = <PropertyViolation>[];

  properties.forEach((key, value) {
    if (kReservedPropertyKeys.contains(key) || kBuiltinKeys.contains(key)) {
      violations.add(PropertyViolation(key: key, reason: 'reserved key'));
      return;
    }
    if (value == null) return;

    final declaring = [
      for (final def in covering)
        if (def.properties.containsKey(key)) def,
    ];
    if (declaring.isEmpty) return;

    for (final def in declaring) {
      final prop = def.properties[key]!;
      final reason = _validateValue(prop, value, resolveTitle, isRowOf);
      if (reason != null) {
        violations.add(
          PropertyViolation(
            key: key,
            reason: covering.length > 1
                ? '$reason (database "${def.title}")'
                : reason,
          ),
        );
      }
    }
  });

  return violations;
}

String? _validateValue(
  PropertyDefinition prop,
  Object? value,
  NoteSummary? Function(String title)? resolveTitle,
  bool Function(NoteSummary note, String databaseId)? isRowOf,
) {
  if (value is Map) return 'must not be a nested map';

  switch (prop.type) {
    case PropertyType.text:
      return value is String ? null : 'must be text';

    case PropertyType.number:
      return value is num ? null : 'must be a number, not a string';

    case PropertyType.checkbox:
      return value is bool ? null : 'must be a boolean';

    case PropertyType.date:
      if (value is DateTime) return null;
      if (value is! String) return 'must be a date string';
      if (_dayPattern.hasMatch(value)) return null;
      return DateTime.tryParse(value) == null
          ? 'must be YYYY-MM-DD or an ISO 8601 timestamp'
          : null;

    case PropertyType.select:
      if (value is! String) return 'must be a string';
      final options = prop.options ?? const <String>[];
      return options.contains(value)
          ? null
          : 'is not one of the declared options';

    case PropertyType.multiSelect:
      if (value is! List) return 'must be a list of strings';
      final options = prop.options ?? const <String>[];
      for (final item in value) {
        if (item is! String) return 'items must be strings';
        if (!options.contains(item)) {
          return 'contains "$item" which is not one of the declared options';
        }
      }
      return null;

    case PropertyType.relation:
      if (value is! List) return 'must be a list of [[Title]] wikilinks';
      for (final item in value) {
        if (item is! String) return 'items must be [[Title]] wikilink strings';
        final match = _wholeWikilink.firstMatch(item);
        if (match == null) return '"$item" is not a [[Title]] wikilink';
        final inner = match.group(1)!;
        final pipeIndex = inner.indexOf('|');
        final targetTitle =
            pipeIndex < 0 ? inner : inner.substring(0, pipeIndex);
        final database = prop.database;
        if (database != null && resolveTitle != null && isRowOf != null) {
          final target = resolveTitle(targetTitle);
          if (target != null && !isRowOf(target, database)) {
            return 'relation target "$targetTitle" is not a row of the '
                'constrained database';
          }
        }
      }
      return null;

    case PropertyType.url:
      if (value is! String) return 'must be a string';
      final uri = Uri.tryParse(value);
      final ok = uri != null &&
          uri.isAbsolute &&
          (uri.scheme == 'http' || uri.scheme == 'https');
      return ok ? null : 'must be an absolute http(s) URL';
  }
}
