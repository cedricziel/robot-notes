import 'package:meta/meta.dart';

/// Soft editor lock state on a note.
@immutable
class Lock {
  const Lock({required this.holder, required this.expiresAt});

  final String holder;
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => {
        'holder': holder,
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  factory Lock.fromJson(Map<String, dynamic> json) => Lock(
        holder: json['holder'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      );

  @override
  bool operator ==(Object other) =>
      other is Lock &&
      other.holder == holder &&
      other.expiresAt.isAtSameMomentAs(expiresAt);

  @override
  int get hashCode => Object.hash(holder, expiresAt.toUtc());
}

/// Listing-shaped metadata for a note (no content, no lock state).
@immutable
class NoteMeta {
  const NoteMeta({
    required this.id,
    required this.title,
    this.path = '',
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.excerpt = '',
    this.tags = const <String>[],
  });

  final String id;
  final String title;

  /// Folder the note lives in, `/`-separated, no leading/trailing slash.
  /// Empty string means the vault root. Defaults to `''` so callers that
  /// pre-date the vault-structure change (and any server response that
  /// omits it) still construct a valid value.
  final String path;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Bounded, markdown-stripped preview of the note's body. Empty when the
  /// server response omits the field.
  final String excerpt;

  /// Computed tag set, in server-provided display casing. Empty when the
  /// server response omits the field.
  final List<String> tags;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'version': version,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'excerpt': excerpt,
        'tags': tags,
      };

  factory NoteMeta.fromJson(Map<String, dynamic> json) => NoteMeta(
        id: json['id'] as String,
        title: json['title'] as String,
        path: json['path'] as String? ?? '',
        version: json['version'] as int,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
        excerpt: json['excerpt'] as String? ?? '',
        tags: json['tags'] == null
            ? const <String>[]
            : (json['tags'] as List).cast<String>(),
      );

  @override
  bool operator ==(Object other) =>
      other is NoteMeta &&
      other.id == id &&
      other.title == title &&
      other.path == path &&
      other.version == version &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.updatedAt.isAtSameMomentAs(updatedAt) &&
      other.excerpt == excerpt &&
      _listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(
        id,
        title,
        path,
        version,
        createdAt.toUtc(),
        updatedAt.toUtc(),
        excerpt,
        Object.hashAll(tags),
      );
}

/// Full note shape returned by `GET /notes/{id}`.
@immutable
class Note {
  const Note({
    required this.id,
    required this.title,
    this.path = '',
    required this.content,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.lock,
    this.tags = const <String>[],
    this.properties = const <String, Object?>{},
    this.type,
  });

  final String id;
  final String title;

  /// Folder the note lives in, `/`-separated, no leading/trailing slash.
  /// Empty string means the vault root.
  final String path;
  final String content;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Lock? lock;

  /// Computed tag set (frontmatter `tags` merged with inline `#tag` tokens;
  /// see `notes-storage`), in server-provided display casing. Empty when
  /// the server response omits the field.
  final List<String> tags;

  /// Every frontmatter key other than the storage-managed and
  /// server-interpreted keys (see the `databases` capability), values
  /// encoded as JSON. Empty when the note carries no such keys.
  final Map<String, Object?> properties;

  /// `"database"` when this note is a database definition (`type: database`
  /// frontmatter); `null` for an ordinary note.
  final String? type;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'content': content,
        'version': version,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'lock': lock?.toJson(),
        'tags': tags,
        'properties': properties,
        if (type != null) 'type': type,
      };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String,
        title: json['title'] as String,
        path: json['path'] as String? ?? '',
        content: json['content'] as String,
        version: json['version'] as int,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
        lock: json['lock'] == null
            ? null
            : Lock.fromJson(json['lock'] as Map<String, dynamic>),
        tags: json['tags'] == null
            ? const <String>[]
            : (json['tags'] as List).cast<String>(),
        properties: json['properties'] == null
            ? const <String, Object?>{}
            : (json['properties'] as Map).cast<String, Object?>(),
        type: json['type'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Note &&
      other.id == id &&
      other.title == title &&
      other.path == path &&
      other.content == content &&
      other.version == version &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.updatedAt.isAtSameMomentAs(updatedAt) &&
      other.lock == lock &&
      _listEquals(other.tags, tags) &&
      _rawMapEquals(other.properties, properties) &&
      other.type == type;

  @override
  int get hashCode => Object.hash(
        id,
        title,
        path,
        content,
        version,
        createdAt.toUtc(),
        updatedAt.toUtc(),
        lock,
        Object.hashAll(tags),
        _rawMapHash(properties),
        type,
      );
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Summary shape for an invite token (no API key — that lives in the
/// onboarding bundle fetched once per token).
@immutable
class InviteSummary {
  const InviteSummary({
    required this.token,
    required this.label,
    required this.createdAt,
    required this.expiresAt,
    required this.expired,
    this.burnedAt,
  });

  final String token;
  final String label;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? burnedAt;
  final bool expired;

  Map<String, dynamic> toJson() => {
        'token': token,
        'label': label,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'burned_at': burnedAt?.toUtc().toIso8601String(),
        'expired': expired,
      };

  factory InviteSummary.fromJson(Map<String, dynamic> json) => InviteSummary(
        token: json['token'] as String,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
        burnedAt: json['burned_at'] == null
            ? null
            : DateTime.parse(json['burned_at'] as String).toUtc(),
        expired: json['expired'] as bool,
      );

  @override
  bool operator ==(Object other) =>
      other is InviteSummary &&
      other.token == token &&
      other.label == label &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.expiresAt.isAtSameMomentAs(expiresAt) &&
      ((other.burnedAt == null && burnedAt == null) ||
          (other.burnedAt != null &&
              burnedAt != null &&
              other.burnedAt!.isAtSameMomentAs(burnedAt!))) &&
      other.expired == expired;

  @override
  int get hashCode => Object.hash(
        token,
        label,
        createdAt.toUtc(),
        expiresAt.toUtc(),
        burnedAt?.toUtc(),
        expired,
      );
}

/// The typed kind of a database property. Wire values are the spec's
/// snake_case strings (see `specs/databases/spec.md`, "Property definitions
/// have a key, a type, and type-specific options").
enum PropertyType {
  text('text'),
  number('number'),
  checkbox('checkbox'),
  date('date'),
  select('select'),
  multiSelect('multi_select'),
  relation('relation'),
  url('url');

  const PropertyType(this.wire);

  /// The on-the-wire string for this type.
  final String wire;

  /// Resolves a [PropertyType] from its wire-format string, or `null` if
  /// the string does not name a known type.
  static PropertyType? fromWire(String wire) {
    for (final t in PropertyType.values) {
      if (t.wire == wire) return t;
    }
    return null;
  }
}

/// Sort direction for a [SortSpec].
enum SortDirection {
  asc('asc'),
  desc('desc');

  const SortDirection(this.wire);

  final String wire;

  static SortDirection? fromWire(String wire) {
    for (final d in SortDirection.values) {
      if (d.wire == wire) return d;
    }
    return null;
  }
}

/// The kind of a [ViewDefinition].
enum ViewType {
  table('table'),
  list('list'),
  board('board');

  const ViewType(this.wire);

  final String wire;

  static ViewType? fromWire(String wire) {
    for (final v in ViewType.values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}

/// A filter comparison operator. Wire values match the spec's `op` strings
/// exactly (see "Filter expressions are structured, not free text").
enum FilterOp {
  eq('eq'),
  neq('neq'),
  contains('contains'),
  notContains('not_contains'),
  isEmpty('is_empty'),
  isNotEmpty('is_not_empty'),
  gt('gt'),
  gte('gte'),
  lt('lt'),
  lte('lte');

  const FilterOp(this.wire);

  final String wire;

  static FilterOp? fromWire(String wire) {
    for (final o in FilterOp.values) {
      if (o.wire == wire) return o;
    }
    return null;
  }
}

/// A single property's schema within a [DatabaseDefinition].
@immutable
class PropertyDefinition {
  const PropertyDefinition({
    required this.type,
    this.label,
    this.options,
    this.database,
  });

  final PropertyType type;

  /// Optional display label.
  final String? label;

  /// Non-empty, distinct option strings. Required by the spec for
  /// [PropertyType.select] and [PropertyType.multiSelect]; `null` for every
  /// other type.
  final List<String>? options;

  /// For [PropertyType.relation]: the id of the database whose rows are
  /// valid targets. `null` means any note is a valid target.
  final String? database;

  Map<String, dynamic> toJson() => {
        'type': type.wire,
        if (label != null) 'label': label,
        if (options != null) 'options': options,
        if (database != null) 'database': database,
      };

  factory PropertyDefinition.fromJson(Map<String, dynamic> json) {
    final wire = json['type'] as String;
    final type = PropertyType.fromWire(wire);
    if (type == null) {
      throw FormatException('Unknown property type: $wire');
    }
    return PropertyDefinition(
      type: type,
      label: json['label'] as String?,
      options: json['options'] == null
          ? null
          : (json['options'] as List).cast<String>(),
      database: json['database'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PropertyDefinition &&
      other.type == type &&
      other.label == label &&
      other.database == database &&
      _optListEquals(other.options, options);

  @override
  int get hashCode => Object.hash(type, label, database, _optListHash(options));
}

/// The source that determines a database's rows: exactly one of [folder] or
/// [tag] is set.
@immutable
class DatabaseSource {
  const DatabaseSource.folder(this.folder, {this.includeSubfolders = true})
      : tag = null;

  const DatabaseSource.tag(this.tag)
      : folder = null,
        includeSubfolders = true;

  final String? folder;
  final String? tag;

  /// Only meaningful when [folder] is set. Defaults to `true`.
  final bool includeSubfolders;

  Map<String, dynamic> toJson() => folder != null
      ? {'folder': folder, 'include_subfolders': includeSubfolders}
      : {'tag': tag};

  factory DatabaseSource.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('folder')) {
      return DatabaseSource.folder(
        json['folder'] as String,
        includeSubfolders: json['include_subfolders'] as bool? ?? true,
      );
    }
    return DatabaseSource.tag(json['tag'] as String);
  }

  @override
  bool operator ==(Object other) =>
      other is DatabaseSource &&
      other.folder == folder &&
      other.tag == tag &&
      other.includeSubfolders == includeSubfolders;

  @override
  int get hashCode => Object.hash(folder, tag, includeSubfolders);
}

/// A single `{property, direction}` sort key.
@immutable
class SortSpec {
  const SortSpec({required this.property, required this.direction});

  final String property;
  final SortDirection direction;

  Map<String, dynamic> toJson() =>
      {'property': property, 'direction': direction.wire};

  factory SortSpec.fromJson(Map<String, dynamic> json) {
    final wire = json['direction'] as String;
    final direction = SortDirection.fromWire(wire);
    if (direction == null) {
      throw FormatException('Unknown sort direction: $wire');
    }
    return SortSpec(property: json['property'] as String, direction: direction);
  }

  @override
  bool operator ==(Object other) =>
      other is SortSpec &&
      other.property == property &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(property, direction);
}

/// A structured filter expression: either a [Condition] or a combinator
/// ([And] / [Or]) nested to any depth. See the `databases` spec's "Filter
/// expressions are structured, not free text" requirement.
@immutable
sealed class Filter {
  const Filter();

  Map<String, dynamic> toJson();

  factory Filter.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('and')) {
      return And(
        (json['and'] as List)
            .map((e) => Filter.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }
    if (json.containsKey('or')) {
      return Or(
        (json['or'] as List)
            .map((e) => Filter.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }
    return Condition.fromJson(json);
  }
}

/// A leaf filter: `{property, op, value?}`. `value` is omitted for
/// [FilterOp.isEmpty] and [FilterOp.isNotEmpty].
@immutable
class Condition extends Filter {
  const Condition({required this.property, required this.op, this.value});

  final String property;
  final FilterOp op;
  final Object? value;

  @override
  Map<String, dynamic> toJson() => {
        'property': property,
        'op': op.wire,
        if (value != null) 'value': value,
      };

  factory Condition.fromJson(Map<String, dynamic> json) {
    final wire = json['op'] as String;
    final op = FilterOp.fromWire(wire);
    if (op == null) {
      throw FormatException('Unknown filter op: $wire');
    }
    return Condition(
      property: json['property'] as String,
      op: op,
      value: json['value'],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Condition &&
      other.property == property &&
      other.op == op &&
      other.value == value;

  @override
  int get hashCode => Object.hash(property, op, value);
}

/// A conjunction of nested filter expressions: `{"and": [...]}`.
@immutable
class And extends Filter {
  const And(this.and);

  final List<Filter> and;

  @override
  Map<String, dynamic> toJson() => {
        'and': and.map((f) => f.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) =>
      other is And && _filterListEquals(other.and, and);

  @override
  int get hashCode => Object.hashAll(and);
}

/// A disjunction of nested filter expressions: `{"or": [...]}`.
@immutable
class Or extends Filter {
  const Or(this.or);

  final List<Filter> or;

  @override
  Map<String, dynamic> toJson() => {
        'or': or.map((f) => f.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) =>
      other is Or && _filterListEquals(other.or, or);

  @override
  int get hashCode => Object.hashAll(or);
}

/// A named view: type, optional filter/sort/grouping, and column list.
@immutable
class ViewDefinition {
  const ViewDefinition({
    required this.name,
    required this.type,
    this.filter,
    this.sort,
    this.groupBy,
    this.properties,
  });

  final String name;
  final ViewType type;
  final Filter? filter;
  final List<SortSpec>? sort;
  final String? groupBy;

  /// Ordered list of property keys to display.
  final List<String>? properties;

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type.wire,
        if (filter != null) 'filter': filter!.toJson(),
        if (sort != null) 'sort': sort!.map((s) => s.toJson()).toList(),
        if (groupBy != null) 'group_by': groupBy,
        if (properties != null) 'properties': properties,
      };

  factory ViewDefinition.fromJson(Map<String, dynamic> json) {
    final wire = json['type'] as String;
    final type = ViewType.fromWire(wire);
    if (type == null) {
      throw FormatException('Unknown view type: $wire');
    }
    return ViewDefinition(
      name: json['name'] as String,
      type: type,
      filter: json['filter'] == null
          ? null
          : Filter.fromJson(json['filter'] as Map<String, dynamic>),
      sort: json['sort'] == null
          ? null
          : (json['sort'] as List)
              .map((e) => SortSpec.fromJson(e as Map<String, dynamic>))
              .toList(),
      groupBy: json['group_by'] as String?,
      properties: json['properties'] == null
          ? null
          : (json['properties'] as List).cast<String>(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ViewDefinition &&
      other.name == name &&
      other.type == type &&
      other.filter == filter &&
      _sortListEquals(other.sort, sort) &&
      other.groupBy == groupBy &&
      _optListEquals(other.properties, properties);

  @override
  int get hashCode => Object.hash(
        name,
        type,
        filter,
        _sortListHash(sort),
        groupBy,
        _optListHash(properties),
      );
}

/// The full definition returned by `GET /databases/{id}` and accepted by
/// `POST /databases` / `PUT /databases/{id}`.
@immutable
class DatabaseDefinition {
  const DatabaseDefinition({
    required this.id,
    required this.title,
    this.path = '',
    required this.version,
    required this.source,
    required this.properties,
    required this.views,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String path;
  final int version;
  final DatabaseSource source;
  final Map<String, PropertyDefinition> properties;
  final List<ViewDefinition> views;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'version': version,
        'source': source.toJson(),
        'properties': {
          for (final entry in properties.entries)
            entry.key: entry.value.toJson(),
        },
        'views': views.map((v) => v.toJson()).toList(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory DatabaseDefinition.fromJson(Map<String, dynamic> json) {
    final propertiesJson = (json['properties'] as Map).cast<String, dynamic>();
    return DatabaseDefinition(
      id: json['id'] as String,
      title: json['title'] as String,
      path: json['path'] as String? ?? '',
      version: json['version'] as int,
      source: DatabaseSource.fromJson(json['source'] as Map<String, dynamic>),
      properties: {
        for (final entry in propertiesJson.entries)
          entry.key:
              PropertyDefinition.fromJson(entry.value as Map<String, dynamic>),
      },
      views: (json['views'] as List)
          .map((e) => ViewDefinition.fromJson(e as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DatabaseDefinition &&
      other.id == id &&
      other.title == title &&
      other.path == path &&
      other.version == version &&
      other.source == source &&
      _propertyMapEquals(other.properties, properties) &&
      _viewListEquals(other.views, views) &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.updatedAt.isAtSameMomentAs(updatedAt);

  @override
  int get hashCode => Object.hash(
        id,
        title,
        path,
        version,
        source,
        Object.hashAllUnordered(
          properties.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAll(views),
        createdAt.toUtc(),
        updatedAt.toUtc(),
      );
}

/// Listing-shaped database summary: `GET /databases` item.
@immutable
class DatabaseSummary {
  const DatabaseSummary({
    required this.id,
    required this.title,
    this.path = '',
    required this.source,
    required this.rowCount,
  });

  final String id;
  final String title;
  final String path;
  final DatabaseSource source;
  final int rowCount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'source': source.toJson(),
        'row_count': rowCount,
      };

  factory DatabaseSummary.fromJson(Map<String, dynamic> json) =>
      DatabaseSummary(
        id: json['id'] as String,
        title: json['title'] as String,
        path: json['path'] as String? ?? '',
        source: DatabaseSource.fromJson(json['source'] as Map<String, dynamic>),
        rowCount: json['row_count'] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is DatabaseSummary &&
      other.id == id &&
      other.title == title &&
      other.path == path &&
      other.source == source &&
      other.rowCount == rowCount;

  @override
  int get hashCode => Object.hash(id, title, path, source, rowCount);
}

/// A single row item in a [DatabaseQueryPage].
@immutable
class DatabaseRow {
  const DatabaseRow({
    required this.id,
    required this.title,
    this.path = '',
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.tags = const <String>[],
    this.properties = const <String, Object?>{},
    this.invalid = const <String>[],
  });

  final String id;
  final String title;
  final String path;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> tags;

  /// Every declared property present on the row; undeclared frontmatter
  /// keys are omitted.
  final Map<String, Object?> properties;

  /// Declared keys whose stored value fails the type.
  final List<String> invalid;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'version': version,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'tags': tags,
        'properties': properties,
        'invalid': invalid,
      };

  factory DatabaseRow.fromJson(Map<String, dynamic> json) => DatabaseRow(
        id: json['id'] as String,
        title: json['title'] as String,
        path: json['path'] as String? ?? '',
        version: json['version'] as int,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
        tags: json['tags'] == null
            ? const <String>[]
            : (json['tags'] as List).cast<String>(),
        properties: json['properties'] == null
            ? const <String, Object?>{}
            : (json['properties'] as Map).cast<String, Object?>(),
        invalid: json['invalid'] == null
            ? const <String>[]
            : (json['invalid'] as List).cast<String>(),
      );

  @override
  bool operator ==(Object other) =>
      other is DatabaseRow &&
      other.id == id &&
      other.title == title &&
      other.path == path &&
      other.version == version &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.updatedAt.isAtSameMomentAs(updatedAt) &&
      _optListEquals(other.tags, tags) &&
      _rawMapEquals(other.properties, properties) &&
      _optListEquals(other.invalid, invalid);

  @override
  int get hashCode => Object.hash(
        id,
        title,
        path,
        version,
        createdAt.toUtc(),
        updatedAt.toUtc(),
        Object.hashAll(tags),
        Object.hashAllUnordered(
          properties.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAll(invalid),
      );
}

/// One bucket of a grouped query: `{value, count}`.
@immutable
class GroupCount {
  const GroupCount({required this.value, required this.count});

  final Object? value;
  final int count;

  Map<String, dynamic> toJson() => {'value': value, 'count': count};

  factory GroupCount.fromJson(Map<String, dynamic> json) =>
      GroupCount(value: json['value'], count: json['count'] as int);

  @override
  bool operator ==(Object other) =>
      other is GroupCount && other.value == value && other.count == count;

  @override
  int get hashCode => Object.hash(value, count);
}

/// The response body of `POST /databases/{id}/query`.
@immutable
class DatabaseQueryPage {
  const DatabaseQueryPage({
    required this.items,
    this.nextCursor,
    this.groups,
  });

  final List<DatabaseRow> items;
  final String? nextCursor;

  /// Present only when a `group_by` is in effect.
  final List<GroupCount>? groups;

  Map<String, dynamic> toJson() => {
        'items': items.map((i) => i.toJson()).toList(),
        'next_cursor': nextCursor,
        if (groups != null) 'groups': groups!.map((g) => g.toJson()).toList(),
      };

  factory DatabaseQueryPage.fromJson(Map<String, dynamic> json) =>
      DatabaseQueryPage(
        items: (json['items'] as List)
            .map((e) => DatabaseRow.fromJson(e as Map<String, dynamic>))
            .toList(),
        nextCursor: json['next_cursor'] as String?,
        groups: json['groups'] == null
            ? null
            : (json['groups'] as List)
                .map((e) => GroupCount.fromJson(e as Map<String, dynamic>))
                .toList(),
      );

  @override
  bool operator ==(Object other) =>
      other is DatabaseQueryPage &&
      _rowListEquals(other.items, items) &&
      other.nextCursor == nextCursor &&
      _groupListEquals(other.groups, groups);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(items), nextCursor, _groupListHash(groups));
}

/// Request body for `PATCH /notes/{id}/properties`: merges [set] and
/// removes [unset] keys.
@immutable
class PropertyPatch {
  const PropertyPatch({this.set, this.unset});

  final Map<String, Object?>? set;
  final List<String>? unset;

  Map<String, dynamic> toJson() => {
        if (set != null) 'set': set,
        if (unset != null) 'unset': unset,
      };

  factory PropertyPatch.fromJson(Map<String, dynamic> json) => PropertyPatch(
        set: json['set'] == null
            ? null
            : (json['set'] as Map).cast<String, Object?>(),
        unset: json['unset'] == null
            ? null
            : (json['unset'] as List).cast<String>(),
      );

  @override
  bool operator ==(Object other) =>
      other is PropertyPatch &&
      _rawMapEquals(other.set, set) &&
      _optListEquals(other.unset, unset);

  @override
  int get hashCode => Object.hash(_rawMapHash(set), _optListHash(unset));
}

/// Returns the definitions among [definitions] whose source covers a note
/// at [path] carrying [tags] — folder prefix match (respecting
/// `include_subfolders`) or tag membership — excluding the definition note
/// itself (a database never counts its own definition note as a row, even
/// when the definition's own path or tags would otherwise match).
List<DatabaseDefinition> coveringDatabases(
  String path,
  List<String> tags,
  List<DatabaseDefinition> definitions, {
  String? noteId,
  bool isDefinition = false,
}) {
  if (isDefinition) return const [];
  final normalizedTags = tags.map((t) => t.toLowerCase()).toSet();
  return [
    for (final def in definitions)
      if (def.id != noteId && _sourceCovers(def.source, path, normalizedTags))
        def,
  ];
}

bool _sourceCovers(
  DatabaseSource source,
  String path,
  Set<String> normalizedTags,
) {
  if (source.folder != null) {
    return _pathUnder(path, source.folder!, source.includeSubfolders);
  }
  return normalizedTags.contains(source.tag!.toLowerCase());
}

bool _pathUnder(String path, String folder, bool includeSubfolders) {
  if (folder.isEmpty) return true;
  if (path == folder) return true;
  if (!includeSubfolders) return false;
  return path.startsWith('$folder/');
}

bool _optListEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _optListHash<T>(List<T>? list) => list == null ? 0 : Object.hashAll(list);

bool _filterListEquals(List<Filter> a, List<Filter> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sortListEquals(List<SortSpec>? a, List<SortSpec>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _sortListHash(List<SortSpec>? list) =>
    list == null ? 0 : Object.hashAll(list);

bool _viewListEquals(List<ViewDefinition> a, List<ViewDefinition> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _propertyMapEquals(
  Map<String, PropertyDefinition> a,
  Map<String, PropertyDefinition> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

bool _rawMapEquals(Map<String, Object?>? a, Map<String, Object?>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (!_deepEquals(entry.value, b[entry.key])) return false;
  }
  return true;
}

int _rawMapHash(Map<String, Object?>? m) {
  if (m == null) return 0;
  var h = 0;
  for (final entry in m.entries) {
    h ^= Object.hash(entry.key, entry.value);
  }
  return h;
}

bool _deepEquals(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

bool _rowListEquals(List<DatabaseRow> a, List<DatabaseRow> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _groupListEquals(List<GroupCount>? a, List<GroupCount>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _groupListHash(List<GroupCount>? list) =>
    list == null ? 0 : Object.hashAll(list);
