import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/canonical_json.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:server/src/knowledge/type_snapshots.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/storage.dart';

/// Cursor no longer represents one consistent accepted query revision.
class KnowledgeCursorStale implements Exception {}

/// Accepted-only typed queries and bounded outgoing relation traversal.
class KnowledgeQueryService {
  /// Rebuilds derived state from accepted filesystem snapshots without
  /// networking.
  KnowledgeQueryService({
    required this.storage,
    required this.types,
    required this.authorization,
  });

  /// Canonical notes and retained accepted snapshots.
  final Storage storage;

  /// Accepted pinned constraints and guidance.
  final KnowledgeTypeSnapshots types;

  /// Current principal and effective read access.
  final NoteAuthorizationService authorization;

  Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Expected query object');
    }
    return value;
  }

  Future<Map<String, StoredNote>> _accepted() async {
    final result = <String, StoredNote>{};
    for (final summary in await storage.list()) {
      final target = KnowledgeTarget.note(summary.id, summary.path);
      if (!authorization.allows(
        currentKnowledgePrincipal,
        KnowledgeAction.read,
        target,
      )) {
        continue;
      }
      final history = await storage.revisions(summary.id);
      if (history.isEmpty || history.last['deleted'] == true) continue;
      final snapshot = parseFrontmatter(history.last['markdown'] as String);
      try {
        authorization.requireHistoricalRead(
          currentKnowledgePrincipal,
          summary.id,
          snapshot.metadata['path']! as String,
          summary.path,
        );
      } on KnowledgeAccessDeniedException {
        continue;
      }
      final knowledge = snapshot.metadata['knowledge'];
      if (knowledge is! Map<String, Object?> ||
          knowledge['role'] != 'knowledge' ||
          knowledge['format_version'] != 1) {
        continue;
      }
      final metadata = snapshot.metadata;
      final extra = Map<String, Object?>.from(metadata)
        ..removeWhere(
          (key, _) => const {
            'id',
            'title',
            'path',
            'version',
            'created_at',
            'updated_at',
          }.contains(key),
        );
      result[summary.id] = StoredNote(
        id: summary.id,
        title: metadata['title']! as String,
        path: metadata['path']! as String,
        version: metadata['version']! as int,
        createdAt: DateTime.parse(metadata['created_at']! as String),
        updatedAt: DateTime.parse(metadata['updated_at']! as String),
        content: snapshot.body,
        extra: extra,
      );
    }
    return result;
  }

  Map<String, Object?> _knowledge(StoredNote note) =>
      _object(note.extra['knowledge']);

  Object? _value(StoredNote note, String key) => switch (key) {
        'id' => note.id,
        'title' => note.title,
        'path' => note.path,
        'version' => note.version,
        'created_at' => note.createdAt.toIso8601String(),
        'updated_at' => note.updatedAt.toIso8601String(),
        _ => note.extra[key],
      };

  Map<String, List<String>> _relations(StoredNote note, Set<String> readable) =>
      {
        for (final entry in _object(
          _knowledge(note)['relations'] ?? const <String, Object?>{},
        ).entries)
          entry.key: (entry.value! as List<Object?>)
              .cast<String>()
              .where(readable.contains)
              .toList(),
      };

  List<KnowledgeTypeReference> _assigned(StoredNote note) =>
      (_knowledge(note)['types']! as List<Object?>)
          .map(KnowledgeTypeReference.fromJson)
          .toList();

  bool _condition(Object? actual, Map<String, Object?> condition) {
    final value = condition['value'];
    final operator = condition['operator'];
    final empty = actual == null ||
        actual == '' ||
        (actual is List<Object?> && actual.isEmpty);
    switch (operator) {
      case 'eq':
        return actual is num && value is num
            ? actual == value
            : canonicalKnowledgeJson(actual) == canonicalKnowledgeJson(value);
      case 'neq':
        return actual is num && value is num
            ? actual != value
            : canonicalKnowledgeJson(actual) != canonicalKnowledgeJson(value);
      case 'is_empty':
        return empty;
      case 'is_not_empty':
        return !empty;
      case 'contains':
        if (actual == null) return false;
        if (actual is String && value is String) {
          return actual.toLowerCase().contains(value.toLowerCase());
        }
        if (actual is List<Object?>) return actual.contains(value);
        throw const FormatException('Unsupported contains operand');
      case 'gt':
      case 'gte':
      case 'lt':
      case 'lte':
        if (actual == null) return false;
        final comparison = actual is num && value is num
            ? actual.compareTo(value)
            : actual is String &&
                    value is String &&
                    DateTime.tryParse(actual) != null &&
                    DateTime.tryParse(value) != null
                ? actual.compareTo(value)
                : null;
        if (comparison == null) {
          throw const FormatException('Ordering requires number or date');
        }
        return switch (operator) {
          'gt' => comparison > 0,
          'gte' => comparison >= 0,
          'lt' => comparison < 0,
          _ => comparison <= 0
        };
      default:
        throw const FormatException('Unsupported knowledge operator');
    }
  }

  Map<String, Object?> _entry(StoredNote note, Set<String> readable) => {
        'id': note.id,
        'title': note.title,
        'path': note.path,
        'revision': note.version,
        'content': note.content,
        'types': _knowledge(note)['types'],
        'properties': Map<String, Object?>.from(note.extra)
          ..remove('knowledge'),
        'relations': _relations(note, readable),
        if (_knowledge(note).containsKey('evidence'))
          'evidence': _knowledge(note)['evidence'],
      };

  /// Filters and traverses only readable accepted entries; pending content is
  /// absent.
  Future<Map<String, Object?>> query(Map<String, Object?> arguments) =>
      authorization.store.withMutationLock(() async {
        if (!arguments.keys.every(
          const {
            'types',
            'properties',
            'relations',
            'sort',
            'cursor',
            'limit',
            'traversal',
          }.contains,
        )) {
          throw const FormatException('Unsupported knowledge query field');
        }
        final limit = arguments['limit'] as int? ?? 50;
        if (limit < 1 || limit > 200) {
          throw const FormatException('Query limit must be 1 to 200');
        }
        final all = await _accepted();
        final readable = all.keys.toSet();
        final definitions = await types.definitions();
        final resolver = KnowledgeTypeResolver(definitions);
        final typeFilters = (arguments['types'] as List<Object?>? ?? [])
            .map(KnowledgeTypeReference.fromJson)
            .toList();
        final properties = (arguments['properties'] as List<Object?>? ?? [])
            .map(_object)
            .toList();
        final relationFilters = (arguments['relations'] as List<Object?>? ?? [])
            .map(_object)
            .toList();
        final sort = _object(
          arguments['sort'] ?? {'field': 'updated_at', 'direction': 'desc'},
        );
        final field = sort['field']! as String;
        final direction = sort['direction'] as String? ?? 'asc';
        if (!const {'asc', 'desc'}.contains(direction) ||
            field == 'knowledge') {
          throw const FormatException('Unsupported sort');
        }
        final fields = <String, Set<String>>{
          'id': {'text'},
          'title': {'text'},
          'path': {'text'},
          'version': {'number'},
          'created_at': {'date'},
          'updated_at': {'date'},
        };
        final declaredRelations = <String>{};
        for (final definition in definitions) {
          final resolved = resolver.resolve(definition.reference);
          for (final entry in resolved.properties.entries) {
            fields
                .putIfAbsent(entry.key, () => {})
                .add(_object(entry.value)['value_type']! as String);
          }
          declaredRelations.addAll(resolved.relations.keys);
        }
        if (!fields.containsKey(field)) {
          throw const FormatException('Undeclared sort field');
        }
        for (final condition in properties) {
          if (!condition.keys
                  .every(const {'field', 'operator', 'value'}.contains) ||
              !fields.containsKey(condition['field'])) {
            throw const FormatException('Undeclared filter field');
          }
          final operator = condition['operator'];
          if (!const {
            'eq',
            'neq',
            'contains',
            'is_empty',
            'is_not_empty',
            'gt',
            'gte',
            'lt',
            'lte',
          }.contains(operator)) {
            throw const FormatException('Unsupported property operator');
          }
          final kinds = fields[condition['field']]!;
          if (operator == 'contains' &&
              !kinds.any(const {'text', 'list'}.contains)) {
            throw const FormatException('Unsupported contains field');
          }
          if (const {'gt', 'gte', 'lt', 'lte'}.contains(operator) &&
              !(kinds.contains('number') && condition['value'] is num ||
                  kinds.contains('date') &&
                      condition['value'] is String &&
                      DateTime.tryParse(condition['value']! as String) !=
                          null)) {
            throw const FormatException('Unsupported ordering field or value');
          }
        }
        for (final condition in relationFilters) {
          if (!condition.keys.every(
                const {'name', 'target_ids', 'target_types'}.contains,
              ) ||
              !declaredRelations.contains(condition['name']) ||
              ((condition['target_ids'] as List<Object?>? ?? []).isEmpty &&
                  (condition['target_types'] as List<Object?>? ?? [])
                      .isEmpty)) {
            throw const FormatException('Unsupported relation filter');
          }
        }
        final rows = all.values.where((note) {
          if (typeFilters.isNotEmpty &&
              !_assigned(note).any(
                (actual) => typeFilters
                    .any((expected) => resolver.isSubtype(actual, expected)),
              )) {
            return false;
          }
          if (!properties.every(
            (condition) => _condition(
              _value(note, condition['field']! as String),
              condition,
            ),
          )) {
            return false;
          }
          final relations = _relations(note, readable);
          for (final condition in relationFilters) {
            final targets = relations[condition['name']] ?? [];
            final targetIds = (condition['target_ids'] as List<Object?>? ?? [])
                .cast<String>();
            final targetTypes =
                (condition['target_types'] as List<Object?>? ?? [])
                    .map(KnowledgeTypeReference.fromJson)
                    .toList();
            if (targetIds.isNotEmpty && !targetIds.every(targets.contains)) {
              return false;
            }
            if (targetTypes.isNotEmpty &&
                !targets.any(
                  (id) => _assigned(all[id]!).any(
                    (actual) => targetTypes.any(
                      (expected) => resolver.isSubtype(actual, expected),
                    ),
                  ),
                )) {
              return false;
            }
          }
          return true;
        }).toList()
          ..sort((left, right) {
            final a = _value(left, field);
            final b = _value(right, field);
            final comparison = a == null
                ? b == null
                    ? 0
                    : 1
                : b == null
                    ? -1
                    : a is num && b is num
                        ? a.compareTo(b)
                        : a is String && b is String
                            ? a.compareTo(b)
                            : throw const FormatException(
                                'Unsupported sort value',
                              );
            return comparison == 0
                ? left.id.compareTo(right.id)
                : direction == 'desc'
                    ? -comparison
                    : comparison;
          });
        final normalized = <String, Object?>{
          'types': arguments['types'] ?? <Object?>[],
          'properties': arguments['properties'] ?? <Object?>[],
          'relations': arguments['relations'] ?? <Object?>[],
          'sort': sort,
          'limit': limit,
          'traversal': arguments['traversal'] ?? <String, Object?>{},
        };
        final binding = sha256
            .convert(
              utf8.encode(
                canonicalKnowledgeJson([
                  authorization.vaultId,
                  currentKnowledgePrincipal.id,
                  normalized,
                ]),
              ),
            )
            .toString();
        final sorted = all.keys.toList()..sort();
        final revision = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  authorization.store.revision,
                  for (final id in sorted)
                    [id, all[id]!.version, _knowledge(all[id]!)],
                ]),
              ),
            )
            .toString();
        var offset = 0;
        if (arguments['cursor'] != null) {
          final cursor = jsonDecode(
            utf8.decode(base64Url.decode(arguments['cursor']! as String)),
          ) as Map<String, dynamic>;
          if (cursor['binding'] != binding) {
            throw const FormatException('Cursor query binding changed');
          }
          if (cursor['revision'] != revision) throw KnowledgeCursorStale();
          offset = cursor['offset'] as int;
          if (offset < 0 || offset > rows.length) {
            throw const FormatException('Invalid cursor offset');
          }
        }
        final page = rows.skip(offset).take(limit).toList();
        final traversal =
            _object(arguments['traversal'] ?? const <String, Object?>{});
        final depth = traversal['max_depth'] as int? ?? 0;
        final maxNodes = traversal['max_nodes'] as int? ?? 200;
        final names =
            (traversal['relations'] as List<Object?>? ?? []).cast<String>();
        if (depth < 0 || depth > 2 || maxNodes < 1 || maxNodes > 200) {
          throw const FormatException('Invalid traversal bounds');
        }
        final nodes = <String, StoredNote>{};
        var truncated = false;
        var frontier = page;
        for (var level = 0; level <= depth; level++) {
          final next = <StoredNote>[];
          for (final note in frontier) {
            if (nodes.containsKey(note.id)) continue;
            if (nodes.length == maxNodes) {
              truncated = true;
              continue;
            }
            nodes[note.id] = note;
            if (level == depth) continue;
            for (final entry in _relations(note, readable).entries) {
              if (names.isNotEmpty && !names.contains(entry.key)) continue;
              for (final id in entry.value) {
                if (!nodes.containsKey(id) &&
                    !next.any((node) => node.id == id)) {
                  if (next.length >= maxNodes) {
                    truncated = true;
                  } else {
                    next.add(all[id]!);
                  }
                }
              }
            }
          }
          frontier = next;
        }
        final nextOffset = offset + page.length;
        return {
          'items': [for (final note in page) _entry(note, readable)],
          'nodes': [for (final note in nodes.values) _entry(note, readable)],
          'truncated': truncated,
          'next_cursor': nextOffset < rows.length
              ? base64Url.encode(
                  utf8.encode(
                    jsonEncode({
                      'binding': binding,
                      'revision': revision,
                      'offset': nextOffset,
                    }),
                  ),
                )
              : null,
          'index_revision': revision,
        };
      });
}
