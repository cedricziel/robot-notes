import '../api/api_client.dart';
import '../api/api_exceptions.dart';

/// Looks up note titles matching a query, for `[[`-link autocomplete and
/// relation-property pickers.
///
/// Standalone (not tied to an open note) so it can be reused by the
/// property-panel relation editor and the schema editor's relation target
/// picker, not just [NoteController]'s link autocomplete.
///
/// [databaseRestriction], when given, replaces the default `GET /search`
/// lookup with a caller-supplied lookup — e.g. restricting matches to rows
/// of a particular database. It is a plain function for now: the server's
/// `queryDatabase` client method (which the design calls for wiring this
/// through eventually) doesn't exist yet.
class TitleSearchService {
  TitleSearchService({required RobotNotesClient api, this.databaseRestriction})
    : _api = api;

  final RobotNotesClient _api;

  /// Optional replacement for the default `GET /search` lookup, e.g. to
  /// restrict matches to a single database's rows once `queryDatabase`
  /// exists on [RobotNotesClient]. Receives the same (non-blank) query
  /// [search] was called with.
  final Future<List<String>> Function(String query)? databaseRestriction;

  /// Looks up note titles matching [query]. Returns no titles (and issues
  /// no request) for a blank query, and swallows request failures —
  /// autocomplete has nothing useful to show for an error beyond "no
  /// matches".
  Future<List<String>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <String>[];
    final restriction = databaseRestriction;
    if (restriction != null) return restriction(query);
    try {
      final hits = await _api.search(q: query);
      return <String>{for (final h in hits) h.title}.toList();
    } on ApiException {
      return const <String>[];
    }
  }
}
