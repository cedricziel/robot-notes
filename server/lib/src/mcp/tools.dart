import 'package:meta/meta.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tool_results.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:shared/shared.dart';

/// Default page size for `search_notes`, matching `GET /search`'s default
/// (independent of `list_notes`'s default, which matches `GET /notes`).
const int kMcpSearchDefaultLimit = 20;

/// How many times `append_to_note` re-reads and retries its write after
/// losing a version race before giving up with a `version_conflict`.
const int kMcpAppendMaxRetries = 3;

/// Case-insensitive Crockford base-32 ULID charset, matching the ids
/// `package:ulid` generates for [Storage] (which itself always stores them
/// lowercase).
final RegExp _ulidPattern = RegExp(r'^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{26}$');

/// Validates `args['id']` as a well-formed ULID before any tool touches
/// [Storage], which builds file paths by plain string interpolation and
/// would otherwise follow an id like `../secret` outside `content/`.
/// Returns the id when valid, `null` otherwise — callers must treat `null`
/// as a `not_found` tool error rather than a distinguishable one, so a
/// probing client learns nothing about why the id was rejected.
String? _requiredNoteId(Map<String, Object?> args) {
  final id = args['id']! as String;
  return _ulidPattern.hasMatch(id) ? id : null;
}

/// Reads a required string argument. Safe to assume present and correctly
/// typed: [McpToolRegistry._validateArgs] already checked both before any
/// handler runs.
String _requiredString(Map<String, Object?> args, String key) =>
    args[key]! as String;

/// Signature every tool handler implements. [args] have already passed
/// schema validation; [principal] is the authenticated caller.
typedef McpToolHandler = Future<Map<String, Object?>> Function(
  Map<String, Object?> args,
  McpPrincipal principal,
);

/// One entry in the fixed `tools/list` catalog: its name, description,
/// JSON Schema `inputSchema`, whether it requires `notes:write`, and the
/// handler that implements it.
@immutable
class McpTool {
  /// Creates a tool definition.
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.requiresWrite,
    required this.handler,
  });

  /// The tool name as it appears in `tools/list` and `tools/call`.
  final String name;

  /// Human-readable description an agent uses to decide when to call this
  /// tool relative to the others in the catalog.
  final String description;

  /// JSON Schema (type `object`) describing the accepted `arguments`.
  final Map<String, Object?> inputSchema;

  /// Whether this tool requires the `notes:write` scope (as opposed to
  /// `notes:read`).
  final bool requiresWrite;

  /// Implements the tool. Only invoked once `args` have passed schema
  /// validation and the principal has the required scope.
  final McpToolHandler handler;
}

/// Thrown by [McpToolRegistry.call] when [name] does not match any
/// registered tool. The MCP handler maps this to JSON-RPC -32602.
class McpUnknownToolException implements Exception {
  /// Creates an exception naming the unrecognised tool.
  const McpUnknownToolException(this.name);

  /// The tool name that was requested.
  final String name;

  @override
  String toString() => 'McpUnknownToolException: $name';
}

/// Thrown by [McpToolRegistry.call] when the caller-supplied `arguments`
/// do not satisfy a tool's declared `inputSchema`: wrong JSON type, an
/// out-of-range integer, or a missing required key. The MCP handler maps
/// this to JSON-RPC -32602.
///
/// Contrast with `toolFail`, which reports a *semantic* failure (an empty
/// title, a blank search query) as a successful JSON-RPC result with
/// `isError: true` — the shape is valid, the operation is refused.
class McpInvalidParamsException implements Exception {
  /// Creates an exception describing which part of the schema was
  /// violated.
  const McpInvalidParamsException(this.message);

  /// Human-readable description of the violation.
  final String message;

  @override
  String toString() => 'McpInvalidParamsException: $message';
}

/// Registry of the seven fixed note tools exposed over `/mcp`.
///
/// Built once per server from [AppDeps] via [McpToolRegistry.forDeps];
/// tests may also build one directly from a hand-picked [List] of
/// [McpTool]s.
class McpToolRegistry {
  /// Wraps [tools] as the registry's fixed catalog, in declaration order.
  McpToolRegistry(List<McpTool> tools)
      : _tools = List.unmodifiable(tools),
        _byName = {for (final tool in tools) tool.name: tool};

  /// Builds the seven note tools wired to [deps]'s services.
  factory McpToolRegistry.forDeps(AppDeps deps) => McpToolRegistry([
        _listNotesTool(deps.metaIndex),
        _getNoteTool(deps.storage, deps.lockManager),
        _searchNotesTool(deps.searchIndex),
        _createNoteTool(deps.noteWriteService),
        _updateNoteTool(deps.storage, deps.noteWriteService, deps.lockManager),
        _appendToNoteTool(
          deps.storage,
          deps.noteWriteService,
          deps.lockManager,
        ),
        _deleteNoteTool(deps.noteWriteService, deps.lockManager),
      ]);

  final List<McpTool> _tools;
  final Map<String, McpTool> _byName;

  /// The fixed tool catalog, in declaration order.
  List<McpTool> get tools => _tools;

  /// The `tools/list` result payload. The catalog is never paginated, so
  /// there is no `nextCursor`, and it does not vary with the caller's
  /// scopes.
  Map<String, Object?> listResult() => {
        'tools': [
          for (final tool in _tools)
            {
              'name': tool.name,
              'description': tool.description,
              'inputSchema': tool.inputSchema,
            },
        ],
      };

  /// Dispatches a `tools/call` to the tool named [name].
  ///
  /// Throws [McpUnknownToolException] when no tool is registered under
  /// [name]. Returns a `toolFail(kErrorInsufficientScope)` result — not a
  /// thrown error — when [principal] lacks the tool's required scope, per
  /// the "Scopes gate write tools" requirement. Throws
  /// [McpInvalidParamsException] when [args] violate the tool's declared
  /// schema. Otherwise runs the tool's handler and returns its result.
  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> args,
    McpPrincipal principal,
  ) async {
    final tool = _byName[name];
    if (tool == null) throw McpUnknownToolException(name);

    final requiredScope =
        tool.requiresWrite ? kScopeNotesWrite : kScopeNotesRead;
    if (!principal.scopes.contains(requiredScope)) {
      return toolFail(kErrorInsufficientScope);
    }

    _validateArgs(tool, args);
    return tool.handler(args, principal);
  }

  void _validateArgs(McpTool tool, Map<String, Object?> args) {
    final properties =
        (tool.inputSchema['properties'] as Map<String, Object?>?) ?? const {};
    final required =
        (tool.inputSchema['required'] as List<Object?>?)?.cast<String>() ??
            const [];

    for (final key in required) {
      if (!args.containsKey(key) || args[key] == null) {
        throw McpInvalidParamsException('$key is required');
      }
    }

    for (final entry in args.entries) {
      final rawSchema = properties[entry.key];
      if (rawSchema is! Map<String, Object?>) continue;
      final value = entry.value;
      if (value == null) continue;
      switch (rawSchema['type']) {
        case 'string':
          if (value is! String) {
            throw McpInvalidParamsException('${entry.key} must be a string');
          }
        case 'integer':
          if (value is! int) {
            throw McpInvalidParamsException(
              '${entry.key} must be an integer',
            );
          }
          final minimum = rawSchema['minimum'] as int?;
          final maximum = rawSchema['maximum'] as int?;
          if (minimum != null && value < minimum) {
            throw McpInvalidParamsException(
              '${entry.key} must be >= $minimum',
            );
          }
          if (maximum != null && value > maximum) {
            throw McpInvalidParamsException(
              '${entry.key} must be <= $maximum',
            );
          }
      }
    }
  }
}

McpTool _listNotesTool(MetaIndex metaIndex) => McpTool(
      name: 'list_notes',
      description:
          'List note metadata (id, title, version, timestamps — no content), '
          'oldest-id-first with cursor pagination. Use this to browse the '
          'workspace, or before create_note to check whether a similarly '
          'titled note already exists.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': kMaxPageSize},
          'after': {'type': 'string'},
        },
        'required': <String>[],
      },
      requiresWrite: false,
      handler: (args, principal) async {
        final limit = (args['limit'] as int?) ?? kDefaultPageSize;
        final after = args['after'] as String?;
        final page = metaIndex.page(after: after, limit: limit);
        return toolOk({
          'items': [
            for (final s in page.items)
              _summaryJson(
                id: s.id,
                title: s.title,
                version: s.version,
                createdAt: s.createdAt,
                updatedAt: s.updatedAt,
              ),
          ],
          'next_cursor': page.nextCursor,
        });
      },
    );

McpTool _getNoteTool(Storage storage, LockManager lockManager) => McpTool(
      name: 'get_note',
      description:
          'Fetch one note by id, including its full content and — if another '
          'actor currently holds the editor lock — who holds it.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      requiresWrite: false,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        try {
          final note = await storage.read(id);
          final lock = lockManager.lockOf(id);
          return toolOk({
            ..._noteJson(note),
            if (lock != null)
              'lock': {
                'holder': lock.holder,
                'expires_at': lock.expiresAt.toUtc().toIso8601String(),
              },
          });
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        }
      },
    );

McpTool _searchNotesTool(SearchIndex searchIndex) => McpTool(
      name: 'search_notes',
      description: 'Full-text search over note titles and content, ranked by '
          'relevance. Always try this before create_note — creating a note '
          'that duplicates an existing one fragments the workspace memory.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': kMaxSearchLimit,
          },
        },
        'required': ['query'],
      },
      requiresWrite: false,
      handler: (args, principal) async {
        final query = _requiredString(args, 'query').trim();
        if (query.isEmpty) {
          return toolFail(
            kErrorValidationFailed,
            message: 'query must not be blank',
          );
        }
        final limit = (args['limit'] as int?) ?? kMcpSearchDefaultLimit;
        try {
          final hits = searchIndex.search(query, limit: limit);
          return toolOk({
            'items': [
              for (final hit in hits)
                {
                  'id': hit.id,
                  'title': hit.title,
                  'snippet': hit.snippet,
                  'rank': hit.rank,
                },
            ],
          });
        } on InvalidSearchQueryException {
          return toolFail(
            kErrorValidationFailed,
            message: 'invalid search query',
          );
        }
      },
    );

McpTool _createNoteTool(NoteWriteService writes) => McpTool(
      name: 'create_note',
      description: 'Create a new note with a title and optional content. Call '
          'search_notes first — only create when no existing note already '
          'covers the topic.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'content': {'type': 'string'},
        },
        'required': ['title'],
      },
      requiresWrite: true,
      handler: (args, principal) async {
        final title = _requiredString(args, 'title');
        if (title.trim().isEmpty) {
          return toolFail(
            kErrorValidationFailed,
            message: 'title must not be blank',
          );
        }
        final content = (args['content'] as String?) ?? '';
        final note = await writes.create(
          title: title,
          content: content,
          actor: principal.actor,
        );
        return toolOk(_noteJson(note));
      },
    );

McpTool _updateNoteTool(
  Storage storage,
  NoteWriteService writes,
  LockManager lockManager,
) =>
    McpTool(
      name: 'update_note',
      description:
          "Replace a note's title and/or content, enforcing optimistic "
          'concurrency via version — the call fails with version_conflict if '
          'the note changed since you last read it. Prefer append_to_note when '
          'you only need to add material to the end of an existing note.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'version': {'type': 'integer'},
          'title': {'type': 'string'},
          'content': {'type': 'string'},
        },
        'required': ['id', 'version'],
      },
      requiresWrite: true,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final version = args['version']! as int;
        final titleArg = args['title'] as String?;
        final contentArg = args['content'] as String?;
        if (titleArg == null && contentArg == null) {
          return toolFail(
            kErrorValidationFailed,
            message: 'title or content is required',
          );
        }
        if (titleArg != null && titleArg.trim().isEmpty) {
          return toolFail(
            kErrorValidationFailed,
            message: 'title must not be blank',
          );
        }

        final conflict = _lockConflict(lockManager, id, principal.actor);
        if (conflict != null) return conflict;

        try {
          final current = await storage.read(id);
          final updated = await writes.update(
            id: id,
            title: titleArg ?? current.title,
            content: contentArg ?? current.content,
            ifMatch: version,
            actor: principal.actor,
          );
          return toolOk(_noteJson(updated));
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        } on VersionConflictException catch (e) {
          return _versionConflictFail(e.current, principal);
        }
      },
    );

McpTool _appendToNoteTool(
  Storage storage,
  NoteWriteService writes,
  LockManager lockManager,
) =>
    McpTool(
      name: 'append_to_note',
      description:
          'Append text to the end of an existing note as a safe server-side '
          'read-modify-write: the server reads the current content, appends '
          'on a new line, and retries automatically if another actor wrote to '
          'the note first. Use this instead of get_note + update_note when you '
          'only need to add to shared memory.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['id', 'text'],
      },
      requiresWrite: true,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final text = _requiredString(args, 'text');
        if (text.trim().isEmpty) {
          return toolFail(
            kErrorValidationFailed,
            message: 'text must not be empty',
          );
        }

        final initialConflict = _lockConflict(lockManager, id, principal.actor);
        if (initialConflict != null) return initialConflict;

        StoredNote current;
        try {
          current = await storage.read(id);
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        }

        for (var attempt = 0; attempt <= kMcpAppendMaxRetries; attempt++) {
          // Re-checked every attempt, not just once up front: another actor
          // may acquire the lock in the gap between a lost version race and
          // this retry.
          final conflict = _lockConflict(lockManager, id, principal.actor);
          if (conflict != null) return conflict;

          final needsNewline =
              current.content.isNotEmpty && !current.content.endsWith('\n');
          final nextContent = current.content.isEmpty
              ? text
              : '${current.content}${needsNewline ? '\n' : ''}$text';
          try {
            final updated = await writes.update(
              id: id,
              title: current.title,
              content: nextContent,
              ifMatch: current.version,
              actor: principal.actor,
            );
            return toolOk({'id': updated.id, 'version': updated.version});
          } on VersionConflictException catch (e) {
            // Another writer landed first — the exception carries the fresh
            // state, so retrying needs no extra read.
            current = e.current;
          } on NoteNotFoundException {
            return toolFail(ErrorCode.notFound.wire);
          }
        }
        return _versionConflictFail(current, principal);
      },
    );

McpTool _deleteNoteTool(NoteWriteService writes, LockManager lockManager) =>
    McpTool(
      name: 'delete_note',
      description: 'Permanently delete a note by id. There is no undo — use '
          'get_note or search_notes first if you are not certain of the '
          'id.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      requiresWrite: true,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final conflict = _lockConflict(lockManager, id, principal.actor);
        if (conflict != null) return conflict;
        try {
          await writes.delete(id: id, actor: principal.actor);
          return toolOk({'id': id, 'deleted': true});
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        }
      },
    );

Map<String, Object?>? _lockConflict(
  LockManager lockManager,
  String noteId,
  String actor,
) {
  final active = lockManager.lockOf(noteId);
  if (active == null || active.holder == actor) return null;
  return toolFail(ErrorCode.locked.wire, details: {'holder': active.holder});
}

/// Builds a `version_conflict` tool error for [current], the note's state
/// after losing the race. `current_content` is omitted for a principal
/// lacking `notes:read` — a write-only token should not be able to read
/// note bodies as a side effect of a failed write.
Map<String, Object?> _versionConflictFail(
  StoredNote current,
  McpPrincipal principal,
) =>
    toolFail(
      ErrorCode.versionConflict.wire,
      details: {
        'current_version': current.version,
        if (principal.canRead) 'current_content': current.content,
      },
    );

/// Builds the metadata-only fields shared by `list_notes` items and the
/// full note JSON `get_note`/`create_note`/`update_note` return.
Map<String, Object?> _summaryJson({
  required String id,
  required String title,
  required int version,
  required DateTime createdAt,
  required DateTime updatedAt,
}) =>
    {
      'id': id,
      'title': title,
      'version': version,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };

Map<String, Object?> _noteJson(StoredNote note) => {
      ..._summaryJson(
        id: note.id,
        title: note.title,
        version: note.version,
        createdAt: note.createdAt,
        updatedAt: note.updatedAt,
      ),
      'content': note.content,
    };
