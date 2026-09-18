import 'package:server/src/search_index.dart' show kServerInterpretedKeys;

/// Narrows a note's frontmatter `extra` map to the `properties` object the
/// REST API exposes: every key other than the server-interpreted ones
/// (`type`, `tags`, `source`, `properties`, `views`) — see the
/// `notes-api` delta's "`properties` SHALL be a JSON object containing
/// every frontmatter key other than the storage-managed and
/// server-interpreted keys" requirement. Storage-managed keys (`id`,
/// `title`, ...) are never present in `extra` to begin with, so only the
/// server-interpreted set needs filtering here.
Map<String, Object?> propertiesOf(Map<String, Object?> extra) => {
      for (final entry in extra.entries)
        if (!kServerInterpretedKeys.contains(entry.key))
          entry.key: entry.value,
    };
