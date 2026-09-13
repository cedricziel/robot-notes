import 'package:sqlite3/sqlite3.dart';

/// Whether the search index database at [dbPath] has a `note_vectors` row
/// for [id], checked via a second raw connection — used by tests across
/// multiple files that need to verify embedding-write behavior, since
/// `SearchIndex` has no public accessor for the vector table.
bool vectorRowExists(String dbPath, String id) {
  final db = sqlite3.open(dbPath);
  try {
    final rows = db.select('SELECT 1 FROM note_vectors WHERE id = ?;', [id]);
    return rows.isNotEmpty;
  } finally {
    db.close();
  }
}
