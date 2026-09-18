import 'package:shared/shared.dart';

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
/// of a particular database. It is a plain function so callers can supply
/// any lookup; [TitleSearchService.forDatabase] builds one backed by
/// `RobotNotesClient.queryDatabase` for the common case of a `relation`
/// property constrained to a single database.
class TitleSearchService {
  TitleSearchService({required RobotNotesClient api, this.databaseRestriction})
    : _api = api;

  /// A [TitleSearchService] whose [databaseRestriction] queries rows of
  /// [databaseId] via `POST /databases/{id}/query`, matching titles that
  /// contain the search query (case-insensitive, per the `contains` filter
  /// op), and returns their titles deduplicated in server order.
  factory TitleSearchService.forDatabase({
    required RobotNotesClient api,
    required String databaseId,
    int limit = 20,
  }) => TitleSearchService(
    api: api,
    databaseRestriction: (query) async {
      final page = await api.queryDatabase(
        databaseId,
        filter: Condition(
          property: 'title',
          op: FilterOp.contains,
          value: query,
        ),
        limit: limit,
      );
      return <String>{for (final row in page.items) row.title}.toList();
    },
  );

  final RobotNotesClient _api;

  /// Optional replacement for the default `GET /search` lookup, e.g. to
  /// restrict matches to a single database's rows. Receives the same
  /// (non-blank) query [search] was called with.
  final Future<List<String>> Function(String query)? databaseRestriction;

  /// Looks up note titles matching [query]. Returns no titles (and issues
  /// no request) for a blank query, and swallows request failures —
  /// autocomplete has nothing useful to show for an error beyond "no
  /// matches".
  Future<List<String>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <String>[];
    try {
      final restriction = databaseRestriction;
      if (restriction != null) return await restriction(query);
      final hits = await _api.search(q: query);
      return <String>{for (final h in hits) h.title}.toList();
    } on ApiException {
      return const <String>[];
    }
  }
}
