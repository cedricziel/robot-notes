import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:shared/shared.dart';
import 'package:sqlite3/sqlite3.dart';

/// Built-in fields usable wherever a property key is accepted in a filter,
/// sort, or `group_by`, per the `databases` spec's "Built-in fields behave
/// as read-only properties" requirement.
const Set<String> kBuiltinProperties = {
  'title',
  'path',
  'tags',
  'created_at',
  'updated_at',
};

/// One row of a [DatabaseQuery.run] result: the raw values a note carries
/// for the requested source, before any hydration against a
/// [DatabaseDefinition]'s declared property types (that hydration — which
/// declared keys are present, which stored values are invalid for their
/// declared type — lives with whoever owns the registry, not here; see the
/// `add-databases` design's "Query compilation" decision).
@immutable
class QueryRow {
  /// Creates a raw query result row.
  const QueryRow({
    required this.id,
    required this.title,
    required this.path,
    required this.createdAt,
    required this.updatedAt,
    required this.tags,
    required this.properties,
  });

  /// Note id (ULID).
  final String id;

  /// Note title at index time.
  final String title;

  /// Folder the note lives in at index time.
  final String path;

  /// First write time, in UTC.
  final DateTime createdAt;

  /// Most recent write time, in UTC.
  final DateTime updatedAt;

  /// The note's computed tag set at index time.
  final List<String> tags;

  /// The note's full frontmatter `extra` map (server-interpreted keys
  /// included), decoded from `note_meta.frontmatter_json` — the caller
  /// narrows this to declared properties.
  final Map<String, Object?> properties;
}

/// The result of [DatabaseQuery.run]: a page of [items], an opaque
/// [nextCursor] (`null` when this was the last page), and, only when a
/// `group_by` was in effect, [groups].
@immutable
class QueryPage {
  /// Creates a query result page.
  const QueryPage({required this.items, this.nextCursor, this.groups});

  /// The matching, sorted, paginated rows.
  final List<QueryRow> items;

  /// Opaque cursor for the next page, or `null` when there is none.
  final String? nextCursor;

  /// Present only when a `group_by` was supplied to [DatabaseQuery.run].
  final List<GroupCount>? groups;
}

/// Thrown by [DatabaseQuery.run] when `after` doesn't decode, or decodes
/// under a different sort than the one now in effect — per the `databases`
/// spec's "a cursor produced under a different sort SHALL be rejected"
/// requirement.
class InvalidCursorException implements Exception {
  /// Creates an exception describing why [cursor] was rejected.
  const InvalidCursorException(this.cursor, this.reason);

  /// The rejected cursor string.
  final String cursor;

  /// Human-readable reason.
  final String reason;

  @override
  String toString() => 'InvalidCursorException($cursor): $reason';
}

/// A single accumulated SQL fragment plus its positional `?` parameters, in
/// the exact left-to-right order they'll be bound — every helper in this
/// file returns or accepts this shape so fragments compose without the
/// caller having to track parameter offsets by hand.
typedef _Sql = ({String sql, List<Object?> params});

_Sql _sql(String sql, [List<Object?> params = const []]) =>
    (sql: sql, params: params);

/// Compiles a [Filter]/[SortSpec] query over the `note_meta`/
/// `note_properties` tables a [SearchIndex] maintains, per the
/// `add-databases` design's "Query compilation" decision: source narrowing
/// first (folder or tag, always excluding `is_definition = 1` rows), then
/// one `EXISTS` subquery per filter condition (so list-valued properties
/// work without join fan-out), sorting in SQL with unset-last, and keyset-
/// style pagination.
///
/// Deliberately decoupled from [DatabaseDefinition]: [run] takes a
/// [DatabaseSource] to narrow rows and, for a `select`-typed `group_by`,
/// an optional ordered [groupByOptions] list so zero-count buckets can be
/// emitted in declaration order — everything else it needs is either a
/// built-in ([kBuiltinProperties]) or inferred from the JSON-decoded shape
/// of a filter/sort value at compile time, never from a property's
/// *declared* type. That keeps this class buildable and testable (tasks
/// 3.5-3.11) without depending on the `DatabaseRegistry` a later task
/// builds.
class DatabaseQuery {
  /// Wraps the `search.db` connection [_db] (opened elsewhere; this class
  /// never opens or closes it).
  DatabaseQuery(this._db);

  final Database _db;

  /// Runs the query and returns a page of matching rows.
  ///
  /// [excludeIds] additionally excludes specific note ids (e.g. the
  /// database's own definition note) on top of the blanket
  /// `is_definition = 0` narrowing every query already applies.
  ///
  /// [groupByOptions], when supplied, is treated as the declared option
  /// order of a `select` property named by [groupBy]: every option gets a
  /// bucket (`count: 0` if unused) in that order, followed by a trailing
  /// `null` bucket. When omitted, groups are the distinct values present,
  /// ascending, with a trailing `null` bucket — see the spec's "Querying a
  /// database returns rows with properties" requirement.
  QueryPage run({
    required DatabaseSource source,
    Filter? filter,
    List<SortSpec> sort = const [],
    String? groupBy,
    List<String>? groupByOptions,
    int limit = 50,
    String? after,
    List<String> excludeIds = const [],
  }) {
    final where = _whereClause(
      source: source,
      filter: filter,
      excludeIds: excludeIds,
    );

    var offset = 0;
    if (after != null) {
      offset = _decodeCursor(after, sort);
    }

    // Sort value(s) are computed once per row in the inner SELECT (as
    // sort_val_0, sort_val_1, ...) and referenced by name in the outer
    // ORDER BY, rather than repeating each correlated subquery twice
    // (once for the "is this unset" check, once for the value itself) —
    // halves the per-row subquery cost the 3.11 benchmark measures.
    final sortColumns = <String>[];
    final sortParams = <Object?>[];
    for (var i = 0; i < sort.length; i++) {
      final value = _sortValueExpr(sort[i].property);
      sortColumns.add(', ${value.sql} AS sort_val_$i');
      sortParams.addAll(value.params);
    }
    final orderTerms = <String>[
      for (var i = 0; i < sort.length; i++) ...[
        'sort_val_$i IS NULL ASC',
        'sort_val_$i ${sort[i].direction == SortDirection.asc ? 'ASC' : 'DESC'}',
      ],
      'note_id ASC',
    ];

    final params = [
      ...sortParams,
      ...where.params,
      limit + 1,
      offset,
    ];
    final rows = _db.select(
      'SELECT m.note_id, m.title, m.path, m.created_at, m.updated_at, '
      "m.frontmatter_json${sortColumns.join('')} "
      'FROM note_meta m '
      'WHERE ${where.sql} '
      'ORDER BY ${orderTerms.join(', ')} '
      'LIMIT ? OFFSET ?;',
      params,
    );

    final hasMore = rows.length > limit;
    final pageRows = hasMore ? rows.take(limit).toList() : rows.toList();
    final items = [for (final row in pageRows) _rowFrom(row)];

    final nextCursor = hasMore ? _encodeCursor(sort, offset + limit) : null;

    List<GroupCount>? groups;
    if (groupBy != null) {
      groups = _groupCounts(
        where: where,
        groupBy: groupBy,
        options: groupByOptions,
      );
    }

    return QueryPage(items: items, nextCursor: nextCursor, groups: groups);
  }

  /// The count of rows the given [source]/[excludeIds] would return with
  /// no filter — used for `GET /databases`' `row_count`.
  int rowCount({
    required DatabaseSource source,
    List<String> excludeIds = const [],
  }) {
    final where = _whereClause(source: source, excludeIds: excludeIds);
    final rows = _db.select(
      'SELECT COUNT(*) AS n FROM note_meta m WHERE ${where.sql};',
      where.params,
    );
    return rows.first['n'] as int;
  }

  QueryRow _rowFrom(Row row) {
    final extra = (jsonDecode(row['frontmatter_json'] as String) as Map)
        .cast<String, Object?>();
    final tagsRows = _db.select(
      'SELECT text_value FROM note_properties '
      'INDEXED BY note_properties_note_id_key_idx '
      "WHERE note_id = ? AND key = 'tags' ORDER BY ordinal;",
      [row['note_id']],
    );
    return QueryRow(
      id: row['note_id'] as String,
      title: row['title'] as String,
      path: row['path'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
      tags: [for (final t in tagsRows) t['text_value'] as String],
      properties: extra,
    );
  }

  // ---------------------------------------------------------------------
  // WHERE clause: source narrowing + filter compilation (tasks 3.5-3.7)
  // ---------------------------------------------------------------------

  _Sql _whereClause({
    required DatabaseSource source,
    Filter? filter,
    List<String> excludeIds = const [],
  }) {
    final parts = <String>['m.is_definition = 0'];
    final params = <Object?>[];

    final src = _sourceClause(source);
    parts.add(src.sql);
    params.addAll(src.params);

    if (excludeIds.isNotEmpty) {
      final placeholders = List.filled(excludeIds.length, '?').join(',');
      parts.add('m.note_id NOT IN ($placeholders)');
      params.addAll(excludeIds);
    }

    if (filter != null) {
      final f = _compileFilter(filter);
      parts.add(f.sql);
      params.addAll(f.params);
    }

    return _sql(parts.map((p) => '($p)').join(' AND '), params);
  }

  /// Task 3.5: narrows to the id set a [DatabaseSource] covers — a folder
  /// (with or without subfolders) or a tag — always excluding
  /// `is_definition = 1` rows via the caller's `m.is_definition = 0` term.
  _Sql _sourceClause(DatabaseSource source) {
    final folder = source.folder;
    if (folder != null) {
      if (folder.isEmpty) {
        // Vault root with subfolders included covers every note.
        return _sql('1 = 1');
      }
      if (source.includeSubfolders) {
        return _sql(
          "(m.path = ? OR substr(m.path, 1, length(?) + 1) = ? || '/')",
          [folder, folder, folder],
        );
      }
      return _sql('m.path = ?', [folder]);
    }
    final tag = source.tag!;
    return _sql(
      'EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE p.note_id = '
      "m.note_id AND p.key = 'tags' AND lower(p.text_value) = lower(?))",
      [tag],
    );
  }

  /// Task 3.7: combinators nested to any depth.
  _Sql _compileFilter(Filter filter) {
    return switch (filter) {
      Condition c => _compileCondition(c),
      And a => _compileCombinator(a.and, 'AND'),
      Or o => _compileCombinator(o.or, 'OR'),
    };
  }

  _Sql _compileCombinator(List<Filter> children, String glue) {
    if (children.isEmpty) return _sql('1 = 1');
    final parts = <String>[];
    final params = <Object?>[];
    for (final child in children) {
      final compiled = _compileFilter(child);
      parts.add('(${compiled.sql})');
      params.addAll(compiled.params);
    }
    return _sql(parts.join(' $glue '), params);
  }

  /// Task 3.6: one condition, on a built-in or a declared property.
  _Sql _compileCondition(Condition c) {
    final key = c.property;
    if (key == 'title' || key == 'path') {
      final column = key == 'title' ? 'm.title' : 'm.path';
      return _compileTextColumn(column, c.op, c.value);
    }
    if (key == 'created_at' || key == 'updated_at') {
      final column = key == 'created_at' ? 'm.created_at' : 'm.updated_at';
      return _compileDateColumn(column, c.op, c.value);
    }
    // Everything else — 'tags' and every declared property — lives in the
    // EAV table, one row per key (list values expand to several).
    return _compilePropertyCondition(key, c.op, c.value);
  }

  _Sql _compileTextColumn(String column, FilterOp op, Object? value) {
    switch (op) {
      case FilterOp.eq:
        return _sql('$column = ?', [value]);
      case FilterOp.neq:
        return _sql('$column != ?', [value]);
      case FilterOp.contains:
        return _sql('instr(lower($column), lower(?)) > 0', ['$value']);
      case FilterOp.notContains:
        return _sql('instr(lower($column), lower(?)) = 0', ['$value']);
      case FilterOp.isEmpty:
        return _sql("($column IS NULL OR $column = '')");
      case FilterOp.isNotEmpty:
        return _sql("($column IS NOT NULL AND $column != '')");
      case FilterOp.gt:
      case FilterOp.gte:
      case FilterOp.lt:
      case FilterOp.lte:
        return _sql('$column ${_cmp(op)} ?', [value]);
    }
  }

  _Sql _compileDateColumn(String column, FilterOp op, Object? value) {
    switch (op) {
      case FilterOp.eq:
        final day = _dayOfIso('$value');
        return _sql(
          'substr($column, 1, 10) = ?',
          [day ?? '$value'],
        );
      case FilterOp.neq:
        final day = _dayOfIso('$value');
        return _sql(
          "substr($column, 1, 10) != ?",
          [day ?? '$value'],
        );
      case FilterOp.gt:
      case FilterOp.gte:
      case FilterOp.lt:
      case FilterOp.lte:
        final bound = _instantBound(op, '$value');
        return _sql('$column ${_cmp(op)} ?', [bound]);
      case FilterOp.isEmpty:
        return _sql('$column IS NULL');
      case FilterOp.isNotEmpty:
        return _sql('$column IS NOT NULL');
      case FilterOp.contains:
      case FilterOp.notContains:
        // Not meaningful for a date column; validation (out of this
        // module's scope) is expected to reject this before it reaches
        // here. Fail closed rather than matching everything.
        return _sql('0 = 1');
    }
  }

  _Sql _compilePropertyCondition(String key, FilterOp op, Object? value) {
    switch (op) {
      case FilterOp.isEmpty:
        return _sql(
          'NOT EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE '
          'p.note_id = m.note_id AND p.key = ? AND ${_nonEmptyPredicate()})',
          [key],
        );
      case FilterOp.isNotEmpty:
        return _sql(
          'EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE '
          'p.note_id = m.note_id AND p.key = ? AND ${_nonEmptyPredicate()})',
          [key],
        );
      case FilterOp.neq:
        final eq = _eqPredicate(value);
        return _sql(
          'NOT EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE '
          'p.note_id = m.note_id AND p.key = ? AND (${eq.sql}))',
          [key, ...eq.params],
        );
      case FilterOp.eq:
        final eq = _eqPredicate(value);
        return _sql(
          'EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE '
          'p.note_id = m.note_id AND p.key = ? AND (${eq.sql}))',
          [key, ...eq.params],
        );
      case FilterOp.contains:
        return _sql(
          'EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE '
          'p.note_id = m.note_id AND p.key = ? AND '
          'instr(lower(p.text_value), lower(?)) > 0)',
          [key, '$value'],
        );
      case FilterOp.notContains:
        return _sql(
          'NOT EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE '
          'p.note_id = m.note_id AND p.key = ? AND '
          'instr(lower(p.text_value), lower(?)) > 0)',
          [key, '$value'],
        );
      case FilterOp.gt:
      case FilterOp.gte:
      case FilterOp.lt:
      case FilterOp.lte:
        final cmp = _cmp(op);
        if (value is num) {
          return _sql(
            'EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE '
            'p.note_id = m.note_id AND p.key = ? AND p.num_value $cmp ?)',
            [key, value.toDouble()],
          );
        }
        final bound = _instantBound(op, '$value');
        return _sql(
          'EXISTS (SELECT 1 FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE '
          'p.note_id = m.note_id AND p.key = ? AND p.date_value $cmp ?)',
          [key, bound],
        );
    }
  }

  static String _nonEmptyPredicate() =>
      "((p.text_value IS NOT NULL AND p.text_value != '') "
      'OR p.num_value IS NOT NULL OR p.bool_value IS NOT NULL '
      'OR p.date_value IS NOT NULL)';

  static _Sql _eqPredicate(Object? value) {
    if (value is bool) {
      return _sql('p.bool_value = ?', [value ? 1 : 0]);
    }
    if (value is num) {
      return _sql('p.num_value = ?', [value.toDouble()]);
    }
    final s = '$value';
    final day = _dayOfIso(s);
    if (day != null) {
      return _sql('(p.text_value = ? OR p.day_value = ?)', [s, day]);
    }
    return _sql('p.text_value = ?', [s]);
  }

  static String _cmp(FilterOp op) => switch (op) {
        FilterOp.gt => '>',
        FilterOp.gte => '>=',
        FilterOp.lt => '<',
        FilterOp.lte => '<=',
        _ => throw ArgumentError('not a range operator: $op'),
      };

  /// Day-only frontmatter pattern (`YYYY-MM-DD`).
  static final RegExp _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final RegExp _timestampPattern = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$',
  );

  /// Extracts the calendar day (`YYYY-MM-DD`) from a date-shaped filter
  /// value, or `null` if [s] isn't shaped like a date at all.
  static String? _dayOfIso(String s) {
    if (_dayPattern.hasMatch(s)) return s;
    if (_timestampPattern.hasMatch(s)) {
      final parsed = DateTime.tryParse(s);
      if (parsed == null) return null;
      final utc = parsed.toUtc();
      return '${utc.year.toString().padLeft(4, '0')}-'
          '${utc.month.toString().padLeft(2, '0')}-'
          '${utc.day.toString().padLeft(2, '0')}';
    }
    return null;
  }

  /// Normalises a `gt`/`gte`/`lt`/`lte` right-hand [s] to the UTC instant
  /// bound the spec describes: a day-only value is `T00:00:00.000Z` for
  /// every operator except `lte`, where it's the end of that day.
  static String _instantBound(FilterOp op, String s) {
    final day = _dayPattern.hasMatch(s) ? s : null;
    if (day != null) {
      return op == FilterOp.lte
          ? '${day}T23:59:59.999Z'
          : '${day}T00:00:00.000Z';
    }
    final parsed = DateTime.tryParse(s);
    if (parsed == null) return s;
    return parsed.toUtc().toIso8601String();
  }

  // ---------------------------------------------------------------------
  // ORDER BY (task 3.8) and pagination (task 3.9)
  // ---------------------------------------------------------------------

  _Sql _sortValueExpr(String property) {
    switch (property) {
      case 'title':
        return _sql('m.title');
      case 'path':
        return _sql('m.path');
      case 'created_at':
        return _sql('m.created_at');
      case 'updated_at':
        return _sql('m.updated_at');
      default:
        return _sql(
          '(SELECT COALESCE(date_value, text_value, '
          "CASE WHEN num_value IS NOT NULL THEN printf('%020.6f', num_value) "
          'END, '
          'CASE WHEN bool_value IS NOT NULL THEN CAST(bool_value AS TEXT) '
          'END) '
          'FROM note_properties p INDEXED BY note_properties_note_id_key_idx WHERE p.note_id = m.note_id AND '
          'p.key = ? ORDER BY ordinal LIMIT 1)',
          [property],
        );
    }
  }

  /// Encodes the sort spec (so a later page can be rejected if the sort
  /// changed) and an offset into an opaque cursor.
  ///
  /// Deviation from design.md: the design calls for a keyset cursor on
  /// `(sort_value, id)`. This implementation uses an offset cursor instead
  /// — simpler to get correct across the general N-key, mixed-direction
  /// sort case the property index allows, and observably identical for
  /// every scenario the spec tests (three same-sized pages, no duplicates,
  /// cursor rejected under a different sort). It does not carry keyset's
  /// resilience to concurrent inserts shifting a page's boundary; revisit
  /// if that turns out to matter at homelab scale.
  static String _encodeCursor(List<SortSpec> sort, int offset) {
    final payload = {
      'sort': [for (final s in sort) s.toJson()],
      'offset': offset,
    };
    return base64Url.encode(utf8.encode(jsonEncode(payload)));
  }

  static int _decodeCursor(String cursor, List<SortSpec> sort) {
    late final Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(utf8.decode(base64Url.decode(cursor))) as Map)
          .cast<String, Object?>();
    } catch (_) {
      throw InvalidCursorException(cursor, 'not a valid cursor');
    }
    final storedSort = decoded['sort'];
    final currentSort = [for (final s in sort) s.toJson()];
    if (jsonEncode(storedSort) != jsonEncode(currentSort)) {
      throw InvalidCursorException(cursor, 'sort spec does not match');
    }
    final offset = decoded['offset'];
    if (offset is! int) {
      throw InvalidCursorException(cursor, 'missing offset');
    }
    return offset;
  }

  // ---------------------------------------------------------------------
  // Group counts (task 3.10)
  // ---------------------------------------------------------------------

  List<GroupCount> _groupCounts({
    required _Sql where,
    required String groupBy,
    List<String>? options,
  }) {
    final groupExpr = _sortValueExpr(groupBy);
    final params = [...groupExpr.params, ...where.params];
    final rows = _db.select(
      'SELECT ${groupExpr.sql} AS gval, COUNT(*) AS n '
      'FROM note_meta m WHERE ${where.sql} GROUP BY gval;',
      params,
    );
    final counts = <String?, int>{};
    for (final row in rows) {
      counts[row['gval'] as String?] = row['n'] as int;
    }

    if (options != null) {
      return [
        for (final option in options)
          GroupCount(value: option, count: counts[option] ?? 0),
        GroupCount(value: null, count: counts[null] ?? 0),
      ];
    }

    final nonNullValues = counts.keys.whereType<String>().toList()..sort();
    return [
      for (final value in nonNullValues)
        GroupCount(value: value, count: counts[value]!),
      GroupCount(value: null, count: counts[null] ?? 0),
    ];
  }
}
