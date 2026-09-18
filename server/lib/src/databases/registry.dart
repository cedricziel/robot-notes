import 'package:logging/logging.dart';
import 'package:server/src/databases/definition.dart';
import 'package:server/src/databases/validation.dart';
import 'package:server/src/storage.dart';
import 'package:shared/shared.dart';

/// In-memory index of every valid database definition, built from
/// `note_meta`/search-index scans and kept current on every write and
/// delete — see design.md's "Definition notes are parsed into an in-memory
/// `DatabaseRegistry`" decision.
///
/// A definition that fails to parse or fails [validateDefinition] is
/// logged (naming the note's path) and simply absent here, matching the
/// `databases` spec's "Invalid definition is not registered" scenario: the
/// note is still served as an ordinary note, it just never appears in
/// `GET /databases` or answers [covering].
class DatabaseRegistry {
  /// Creates an empty registry.
  DatabaseRegistry({Logger? logger})
      : _log = logger ?? Logger('databases.registry');

  final Logger _log;
  final Map<String, DatabaseDefinition> _byId = {};

  /// Every registered (valid) database definition, in no particular order.
  List<DatabaseDefinition> get all => List.unmodifiable(_byId.values);

  /// The registered definition for [id], or `null` if [id] does not name a
  /// registered database (never registered, invalid, or deleted).
  DatabaseDefinition? get(String id) => _byId[id];

  /// Rebuilds the registry from scratch out of [definitions] — pairs of a
  /// note's [NoteSummary] and its frontmatter `extra` map, as the search
  /// index's `note_meta`/definitions scan supplies them (see
  /// `SearchIndex.definitionsSource` in a later group). Notes whose extra
  /// does not carry `type: database` are silently skipped (they simply
  /// aren't definitions); notes that do but fail to parse or validate are
  /// logged and skipped, per the spec's "Invalid definition is not
  /// registered" scenario.
  void rebuild(Iterable<(NoteSummary, Map<String, Object?>)> definitions) {
    _byId.clear();
    for (final (summary, extra) in definitions) {
      _tryRegister(summary, extra);
    }
  }

  /// Registers or unregisters the note described by [summary]/[extra] —
  /// called on every create/update so the registry stays current without a
  /// full [rebuild]. A note whose extra no longer carries `type: database`
  /// (e.g. its `type` key was removed) is unregistered, matching how a
  /// definition that becomes invalid disappears from [all]/[covering].
  void upsert(NoteSummary summary, Map<String, Object?> extra) {
    if (!isDatabaseDefinitionExtra(extra)) {
      _byId.remove(summary.id);
      return;
    }
    _tryRegister(summary, extra);
  }

  /// Unregisters [id], e.g. because its note was deleted. A no-op if [id]
  /// was not registered.
  void remove(String id) => _byId.remove(id);

  void _tryRegister(NoteSummary summary, Map<String, Object?> extra) {
    try {
      final definition = parseDatabaseDefinition(
        id: summary.id,
        title: summary.title,
        path: summary.path,
        extra: extra,
        version: summary.version,
        createdAt: summary.createdAt,
        updatedAt: summary.updatedAt,
      );
      final violations = validateDefinition(definition);
      if (violations.isNotEmpty) {
        _log.warning(
          'Skipping invalid database definition at "${summary.path}" '
          '(${summary.id}): ${violations.join('; ')}',
        );
        _byId.remove(summary.id);
        return;
      }
      _byId[summary.id] = definition;
    } on DefinitionFormatException catch (e) {
      _log.warning(
        'Skipping malformed database definition at "${summary.path}" '
        '(${summary.id}): $e',
      );
      _byId.remove(summary.id);
    }
  }

  /// The registered definitions whose source covers a note at [path]
  /// carrying [tags] — see `coveringDatabases` in `shared`, reused here
  /// rather than reimplemented. A definition never covers its own note
  /// ([noteId]) and a definition note ([isDefinition]) is never covered.
  List<DatabaseDefinition> covering(
    String path,
    Set<String> tags, {
    String? noteId,
    bool isDefinition = false,
  }) =>
      coveringDatabases(
        path,
        tags.toList(),
        all,
        noteId: noteId,
        isDefinition: isDefinition,
      );
}
