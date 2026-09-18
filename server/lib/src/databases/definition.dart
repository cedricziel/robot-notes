import 'package:shared/shared.dart';

/// Thrown by [parseDatabaseDefinition] when a note's frontmatter cannot be
/// shaped into a [DatabaseDefinition] at all — a malformed `source`,
/// `properties`, or `views` value. This is distinct from the *semantic*
/// validation `validateDefinition` (in `validation.dart`) performs: a
/// definition can parse cleanly here and still fail there (e.g. a `select`
/// property with no `options`).
class DefinitionFormatException implements Exception {
  /// Creates a format exception wrapping a human-readable [message].
  DefinitionFormatException(this.message);

  /// Why the frontmatter could not be parsed.
  final String message;

  @override
  String toString() => 'DefinitionFormatException: $message';
}

/// Returns `true` when [extra] (a note's frontmatter, i.e.
/// `StoredNote.extra`) marks the note as a database definition per the
/// `databases` spec's "A database is a note with `type: database`
/// frontmatter" requirement.
bool isDatabaseDefinitionExtra(Map<String, Object?> extra) =>
    extra['type'] == 'database';

/// Parses a note's frontmatter [extra] map into the shared
/// [DatabaseDefinition] DTO.
///
/// This is a server-only wrapper, not a constructor on the shared type
/// itself: the shared DTO's `fromJson` expects the wire shape returned by
/// `GET /databases/{id}`, while a row/definition note's on-disk frontmatter
/// differs in one respect the spec calls out — `source` defaults to the
/// definition note's own folder ([path], with subfolders included) when
/// omitted, and `properties`/`views` may be absent entirely (treated as
/// empty).
///
/// [extra] MUST already satisfy [isDatabaseDefinitionExtra]; callers (the
/// registry) check that first so they can tell "not a database" apart from
/// "malformed database" — the id, title, path, and provided version/
/// timestamps come from [DatabaseDefinition] no other checks against the
/// caller's [Object].
///
/// Throws [DefinitionFormatException] for structurally malformed data.
/// Never throws for semantic issues (reserved key, missing `options`, ...);
/// call [validateDefinition] on the result for those.
DatabaseDefinition parseDatabaseDefinition({
  required String id,
  required String title,
  required String path,
  required Map<String, Object?> extra,
  int version = 1,
  DateTime? createdAt,
  DateTime? updatedAt,
}) {
  if (!isDatabaseDefinitionExtra(extra)) {
    throw DefinitionFormatException(
      'frontmatter does not carry type: database',
    );
  }

  final sourceRaw = extra['source'];
  final DatabaseSource source;
  if (sourceRaw == null) {
    source = DatabaseSource.folder(path);
  } else {
    try {
      source = DatabaseSource.fromJson(_asStringMap(sourceRaw, 'source'));
    } on Exception catch (e) {
      throw DefinitionFormatException('invalid source: $e');
    }
  }

  final properties = <String, PropertyDefinition>{};
  final propertiesRaw = extra['properties'];
  if (propertiesRaw != null) {
    final map = _asStringMap(propertiesRaw, 'properties');
    for (final entry in map.entries) {
      try {
        properties[entry.key] = PropertyDefinition.fromJson(
          _asStringMap(entry.value, 'properties.${entry.key}'),
        );
      } on Exception catch (e) {
        throw DefinitionFormatException('property "${entry.key}": $e');
      }
    }
  }

  final views = <ViewDefinition>[];
  final viewsRaw = extra['views'];
  if (viewsRaw != null) {
    if (viewsRaw is! List) {
      throw DefinitionFormatException('views must be a list');
    }
    for (var i = 0; i < viewsRaw.length; i++) {
      try {
        views.add(
          ViewDefinition.fromJson(_asStringMap(viewsRaw[i], 'views[$i]')),
        );
      } on Exception catch (e) {
        throw DefinitionFormatException('view[$i]: $e');
      }
    }
  }

  final epoch = DateTime.utc(1970);
  return DatabaseDefinition(
    id: id,
    title: title,
    path: path,
    version: version,
    source: source,
    properties: properties,
    views: views,
    createdAt: createdAt ?? epoch,
    updatedAt: updatedAt ?? epoch,
  );
}

Map<String, dynamic> _asStringMap(Object? value, String where) {
  if (value is Map) return value.cast<String, dynamic>();
  throw DefinitionFormatException('$where must be a map');
}
