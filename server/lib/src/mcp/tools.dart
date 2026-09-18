import 'package:meta/meta.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/backlinks.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/databases/definition.dart';
import 'package:server/src/databases/query.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/databases/validation.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/mcp/tool_results.dart';
import 'package:server/src/meta_index.dart' hide InvalidCursorException;
import 'package:server/src/meta_index.dart' as meta_index
    show InvalidCursorException;
import 'package:server/src/note_write_service.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/upload_sessions.dart';
import 'package:server/src/vault_files.dart';
import 'package:shared/shared.dart';

/// Default page size for `search_notes`, matching `GET /search`'s default
/// (independent of `list_notes`'s default, which matches `GET /notes`).
const int kMcpSearchDefaultLimit = 20;

/// How many times `append_to_note` re-reads and retries its write after
/// losing a version race before giving up with a `version_conflict`. An
/// alias for [kAppendMaxRetries] — the retry budget itself lives on
/// [NoteWriteService.append], shared with `POST /notes/{id}/append`.
const int kMcpAppendMaxRetries = kAppendMaxRetries;

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
/// JSON Schema `inputSchema`, MCP spec `annotations`, whether it requires
/// `notes:write`, and the handler that implements it.
@immutable
class McpTool {
  /// Creates a tool definition.
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.annotations,
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

  /// MCP's optional tool-behavior hints (`title`, `readOnlyHint`,
  /// `destructiveHint`, `idempotentHint`, `openWorldHint`) — advisory only,
  /// per the spec: a client must not rely on them for enforcement in place
  /// of the `notes:read`/`notes:write` scope check [McpToolRegistry.call]
  /// already does.
  final Map<String, Object?> annotations;

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

/// Registry of the nineteen fixed note tools exposed over `/mcp`.
///
/// Built once per server from [AppDeps] via [McpToolRegistry.forDeps];
/// tests may also build one directly from a hand-picked [List] of
/// [McpTool]s.
class McpToolRegistry {
  /// Wraps [tools] as the registry's fixed catalog, in declaration order.
  McpToolRegistry(List<McpTool> tools)
      : _tools = List.unmodifiable(tools),
        _byName = {for (final tool in tools) tool.name: tool};

  /// Builds the nineteen note tools wired to [deps]'s services.
  factory McpToolRegistry.forDeps(AppDeps deps) => McpToolRegistry([
        _listNotesTool(deps.metaIndex),
        _getNoteTool(deps.storage, deps.lockManager),
        _searchNotesTool(deps.searchIndex),
        _createNoteTool(deps.noteWriteService),
        _updateNoteTool(deps.storage, deps.noteWriteService, deps.lockManager),
        _appendToNoteTool(deps.noteWriteService),
        _deleteNoteTool(deps.noteWriteService, deps.lockManager),
        _moveNoteTool(deps.storage, deps.noteWriteService, deps.lockManager),
        _getBacklinksTool(deps.metaIndex, deps.linkIndex, deps.storage),
        _createFolderTool(deps.storage, deps.metaIndex),
        _requestUploadTool(deps.uploadSessions, deps.maxUploadSizeBytes),
        _finalizeUploadTool(
          deps.uploadSessions,
          deps.fileStore,
          deps.storage,
          deps.clock,
        ),
        _listDatabasesTool(deps.noteWriteService.registry, deps.searchIndex),
        _getDatabaseTool(deps.noteWriteService.registry),
        _createDatabaseTool(deps.noteWriteService),
        _updateDatabaseTool(
          deps.noteWriteService.registry,
          deps.noteWriteService,
        ),
        _queryDatabaseTool(
          deps.noteWriteService.registry,
          deps.searchIndex,
          deps.metaIndex,
        ),
        _createRowTool(deps.noteWriteService),
        _updatePropertiesTool(deps.noteWriteService),
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
              'annotations': tool.annotations,
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
        case 'number':
          if (value is! num) {
            throw McpInvalidParamsException('${entry.key} must be a number');
          }
        case 'boolean':
          if (value is! bool) {
            throw McpInvalidParamsException('${entry.key} must be a boolean');
          }
        case 'object':
          if (value is! Map) {
            throw McpInvalidParamsException('${entry.key} must be an object');
          }
        case 'array':
          if (value is! List) {
            throw McpInvalidParamsException('${entry.key} must be an array');
          }
      }
    }
  }
}

/// The `annotations` object for a read-only tool: never mutates state, so
/// repeat calls are always safe to retry.
Map<String, Object?> _readOnlyAnnotations(String title) => {
      'title': title,
      'readOnlyHint': true,
      'destructiveHint': false,
      'idempotentHint': true,
      'openWorldHint': false,
    };

/// The `annotations` object for a tool that requires `notes:write`.
/// [destructive] and [idempotent] describe what a repeat call with the same
/// arguments does — see each tool's own annotations for the specific value.
Map<String, Object?> _writeAnnotations(
  String title, {
  required bool destructive,
  required bool idempotent,
}) =>
    {
      'title': title,
      'readOnlyHint': false,
      'destructiveHint': destructive,
      'idempotentHint': idempotent,
      'openWorldHint': false,
    };

McpTool _listNotesTool(MetaIndex metaIndex) => McpTool(
      name: 'list_notes',
      description:
          'List note metadata (id, title, version, timestamps — no content) '
          'with cursor pagination, oldest-id-first by default or '
          "newest-updated-first with sort: 'updated_desc'. This is the "
          'tool for browsing or enumerating everything — to list "all '
          'notes" call it with no arguments and follow next_cursor until '
          "it's null; search_notes has no wildcard query for this and an "
          'empty path/tag filter here still means "no filter", not "no '
          'notes". Also use this before create_note to check whether a '
          'similarly titled note already exists.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': kMaxPageSize},
          'after': {'type': 'string'},
          'sort': {
            'type': 'string',
            'enum': [kSortId, kSortUpdatedDesc],
          },
          'path': {'type': 'string'},
          'tag': {'type': 'string'},
          'title': {'type': 'string'},
        },
        'required': <String>[],
      },
      annotations: _readOnlyAnnotations('List notes'),
      requiresWrite: false,
      handler: (args, principal) async {
        final limit = (args['limit'] as int?) ?? kDefaultPageSize;
        final after = args['after'] as String?;
        final sort = (args['sort'] as String?) ?? kSortId;
        final pathFilter = args['path'] as String?;
        final tagFilter = args['tag'] as String?;
        final titleFilter = args['title'] as String?;
        if (!kSupportedSorts.contains(sort)) {
          return toolFail(kErrorValidationFailed, message: kSortErrorMessage);
        }
        final MetaIndexPage page;
        try {
          page = metaIndex.page(
            after: after,
            limit: limit,
            sort: sort,
            pathPrefix: pathFilter,
            tag: tagFilter,
            title: titleFilter,
          );
        } on meta_index.InvalidCursorException {
          return toolFail(
            kErrorValidationFailed,
            message: 'after is not a valid cursor for this sort',
          );
        }
        return toolOk({
          'items': [
            for (final s in page.items)
              _summaryJson(
                id: s.id,
                title: s.title,
                path: s.path,
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
      annotations: _readOnlyAnnotations('Get note'),
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
          'relevance. query is a literal FTS5 keyword expression, not a '
          'wildcard — there is no query that means "everything", so '
          "'*' is rejected and a generic term like 'notes' only matches "
          'notes whose title or content contains that word. To enumerate '
          'every note instead of searching for one, use list_notes (with '
          'no query) rather than guessing a query here. Always try this '
          'before create_note — creating a note that duplicates an '
          'existing one fragments the workspace memory.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': kMaxSearchLimit,
          },
          'path': {'type': 'string'},
          'tag': {'type': 'string'},
        },
        'required': ['query'],
      },
      annotations: _readOnlyAnnotations('Search notes'),
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
        final pathFilter = args['path'] as String?;
        final tagFilter = args['tag'] as String?;
        try {
          final hits = await searchIndex.search(
            query,
            limit: limit,
            path: pathFilter,
            tag: tagFilter,
          );
          return toolOk({
            'items': [
              for (final hit in hits)
                {
                  'id': hit.id,
                  'title': hit.title,
                  'path': hit.path,
                  'snippet': hit.snippet,
                  'rank': hit.rank,
                },
            ],
          });
        } on InvalidSearchQueryException catch (e) {
          return toolFail(
            kErrorValidationFailed,
            message: 'invalid search query: ${e.reason}. query is a '
                'literal FTS5 keyword expression, not a wildcard — to list '
                'every note use list_notes instead.',
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
          'path': {'type': 'string'},
          'properties': {'type': 'object'},
        },
        'required': ['title'],
      },
      annotations: _writeAnnotations(
        'Create note',
        destructive: false,
        idempotent: false,
      ),
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
        final path = (args['path'] as String?) ?? '';
        final properties =
            (args['properties'] as Map?)?.cast<String, Object?>();
        try {
          final note = await writes.create(
            title: title,
            content: content,
            actor: principal.actor,
            path: path,
            properties: properties,
          );
          return toolOk(_noteJson(note));
        } on PathConflictException {
          return toolFail(kErrorPathConflict);
        } on InvalidPathException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        } on PropertyValidationException catch (e) {
          return toolFail(
            kErrorValidationFailed,
            message: e.violations.join('; '),
          );
        }
      },
    );

McpTool _updateNoteTool(
  Storage storage,
  NoteWriteService writes,
  LockManager lockManager,
) =>
    McpTool(
      name: 'update_note',
      description: "Replace a note's title, content, and/or path, enforcing "
          'optimistic concurrency via version — the call fails with '
          'version_conflict if the note changed since you last read it. '
          'Prefer append_to_note when you only need to add material to the '
          'end of an existing note, or move_note when you only need to '
          'change its folder.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'version': {'type': 'integer'},
          'title': {'type': 'string'},
          'content': {'type': 'string'},
          'path': {'type': 'string'},
          'properties': {'type': 'object'},
        },
        'required': ['id', 'version'],
      },
      annotations: _writeAnnotations(
        'Update note',
        destructive: true,
        idempotent: true,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final version = args['version']! as int;
        final titleArg = args['title'] as String?;
        final contentArg = args['content'] as String?;
        final pathArg = args['path'] as String?;
        final propertiesArg =
            (args['properties'] as Map?)?.cast<String, Object?>();
        if (titleArg == null &&
            contentArg == null &&
            pathArg == null &&
            propertiesArg == null) {
          return toolFail(
            kErrorValidationFailed,
            message: 'title, content, path, or properties is required',
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
            path: pathArg,
            properties: propertiesArg,
          );
          return toolOk(_noteJson(updated));
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        } on PathConflictException {
          return toolFail(kErrorPathConflict);
        } on InvalidPathException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        } on VersionConflictException catch (e) {
          return _versionConflictFail(e.current, principal);
        } on PropertyValidationException catch (e) {
          return toolFail(
            kErrorValidationFailed,
            message: e.violations.join('; '),
          );
        }
      },
    );

McpTool _appendToNoteTool(NoteWriteService writes) => McpTool(
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
      annotations: _writeAnnotations(
        'Append to note',
        destructive: false,
        idempotent: false,
      ),
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

        try {
          final updated = await writes.append(
            id: id,
            text: text,
            actor: principal.actor,
          );
          return toolOk({'id': updated.id, 'version': updated.version});
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        } on LockedException catch (e) {
          return toolFail(
            ErrorCode.locked.wire,
            details: {'holder': e.current.holder},
          );
        } on VersionConflictException catch (e) {
          return _versionConflictFail(e.current, principal);
        }
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
      annotations: _writeAnnotations(
        'Delete note',
        destructive: true,
        idempotent: true,
      ),
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

McpTool _moveNoteTool(
  Storage storage,
  NoteWriteService writes,
  LockManager lockManager,
) =>
    McpTool(
      name: 'move_note',
      description:
          'Move a note to a different folder without changing its title or '
          'content, enforcing the same optimistic-concurrency version check '
          'and lock check as update_note.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'version': {'type': 'integer'},
          'path': {'type': 'string'},
        },
        'required': ['id', 'version', 'path'],
      },
      annotations: _writeAnnotations(
        'Move note',
        destructive: false,
        idempotent: true,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final version = args['version']! as int;
        final path = _requiredString(args, 'path');

        final conflict = _lockConflict(lockManager, id, principal.actor);
        if (conflict != null) return conflict;

        try {
          final current = await storage.read(id);
          final updated = await writes.update(
            id: id,
            title: current.title,
            content: current.content,
            ifMatch: version,
            actor: principal.actor,
            path: path,
          );
          return toolOk(_noteJson(updated));
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        } on PathConflictException {
          return toolFail(kErrorPathConflict);
        } on InvalidPathException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        } on VersionConflictException catch (e) {
          return _versionConflictFail(e.current, principal);
        }
      },
    );

McpTool _getBacklinksTool(
  MetaIndex metaIndex,
  LinkIndex linkIndex,
  Storage storage,
) =>
    McpTool(
      name: 'get_backlinks',
      description:
          'List every note that links to the given note, each with a short '
          'snippet of surrounding context — mirrors '
          'GET /notes/{id}/backlinks.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      annotations: _readOnlyAnnotations('Get backlinks'),
      requiresWrite: false,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        try {
          final entries = await computeBacklinks(
            targetId: id,
            metaIndex: metaIndex,
            linkIndex: linkIndex,
            storage: storage,
          );
          return toolOk({
            'items': [
              for (final entry in entries)
                {
                  'id': entry.id,
                  'title': entry.title,
                  'snippet': entry.snippet,
                },
            ],
          });
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        }
      },
    );

McpTool _createFolderTool(Storage storage, MetaIndex metaIndex) => McpTool(
      name: 'create_folder',
      description:
          'Create an empty folder (and any missing intermediate folders) at '
          'the given path, mirroring POST /notes/tree. Succeeds as a no-op '
          'if the folder already exists — there is no error case that '
          'distinguishes "created" from "already existed".',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      annotations: _writeAnnotations(
        'Create folder',
        destructive: false,
        idempotent: true,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final path = _requiredString(args, 'path');
        if (path.isEmpty) {
          return toolFail(
            kErrorValidationFailed,
            message: 'path must not be empty',
          );
        }
        try {
          final result = await storage.createFolder(path);
          final noteCount =
              metaIndex.all.where((s) => s.path == result.path).length;
          // Only a folder with no notes is marker-backed on disk (per
          // Storage.createFolder); registering a note-backed folder here
          // too would leave it listed forever once its real notes are
          // removed.
          if (noteCount == 0) metaIndex.registerEmptyFolder(result.path);
          return toolOk({'path': result.path, 'note_count': noteCount});
        } on InvalidPathException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        }
      },
    );

McpTool _requestUploadTool(
  UploadSessionStore uploadSessions,
  int maxUploadSizeBytes,
) =>
    McpTool(
      name: 'request_upload',
      description:
          'Reserve a single-use upload slot for a file at the given path '
          "and filename, returning an upload_url to PUT the file's raw "
          'bytes to (no Authorization header needed — the token itself is '
          'the credential) and a token to pass to finalize_upload once the '
          "PUT completes. Use this instead of embedding a file's bytes "
          'directly in a tool call — the whole point is to keep them out '
          'of this call entirely.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'filename': {'type': 'string'},
          'size_bytes': {'type': 'integer', 'minimum': 0},
        },
        'required': ['path', 'filename'],
      },
      annotations: _writeAnnotations(
        'Request upload',
        destructive: false,
        idempotent: false,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final path = _requiredString(args, 'path');
        final filename = _requiredString(args, 'filename');
        final sizeBytes = args['size_bytes'] as int?;
        if (sizeBytes != null && sizeBytes > maxUploadSizeBytes) {
          return toolFail(kErrorPayloadTooLarge);
        }
        final reserved = uploadSessions.reserve(
          path: path,
          filename: filename,
          maxBytes: maxUploadSizeBytes,
        );
        return toolOk({
          'upload_url': '/notes/file-uploads/${reserved.token}',
          'token': reserved.token,
          'expires_at': reserved.expiresAt.toIso8601String(),
        });
      },
    );

McpTool _finalizeUploadTool(
  UploadSessionStore uploadSessions,
  FileStore fileStore,
  Storage storage,
  Clock clock,
) =>
    McpTool(
      name: 'finalize_upload',
      description:
          'Place a completed upload (see request_upload) into the vault at '
          'the path/filename it was reserved for. Call this once the PUT to '
          "upload_url has succeeded — it's the only step that actually "
          'writes the file.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'token': {'type': 'string'},
        },
        'required': ['token'],
      },
      annotations: _writeAnnotations(
        'Finalize upload',
        destructive: false,
        idempotent: false,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final token = _requiredString(args, 'token');
        try {
          final result = await uploadSessions.finalize(token, fileStore);
          storage.registerFile(
            StoredFile(
              relativePath: vaultRelativePath(
                path: result.path,
                filename: result.filename,
              ),
              size: result.size,
              updatedAt: clock.nowUtc(),
            ),
          );
          return toolOk({
            'path': result.path,
            'filename': result.filename,
            'size': result.size,
            'content_type': result.contentType,
          });
        } on UploadSessionNotFoundException {
          return toolFail(
            kErrorValidationFailed,
            message: 'token is unknown, expired, or not yet uploaded',
          );
        } on FileCollisionException {
          return toolFail(kErrorPathConflict);
        }
      },
    );

/// Shared filter-grammar text embedded in every database tool's
/// description so an agent needs no external doc to build one, per the
/// `mcp-server` spec's "Tool descriptions SHALL state ... the filter
/// grammar" requirement.
const String _kFilterGrammar =
    'A filter is either a condition {"property","op","value?"} or a '
    'combinator {"and":[...]}/{"or":[...]} nested to any depth. op is one '
    'of eq, neq, contains, not_contains, is_empty, is_not_empty, gt, gte, '
    'lt, lte. is_empty/is_not_empty take no value. contains/not_contains '
    'apply to text, url, multi_select, relation, tags, and title '
    '(case-insensitive ASCII substring for text-like, membership for '
    'list-like). gt/gte/lt/lte apply to number and date (including '
    'created_at/updated_at); eq/neq on date compare the calendar day, '
    'gt/gte/lt/lte compare the instant.';

/// Shared per-type value-encoding text embedded in every database tool's
/// description, per the same requirement.
const String _kEncodingTable =
    'Property value encoding per type: text -> string; number -> a JSON '
    'number; checkbox -> a JSON boolean; date -> "YYYY-MM-DD" or an ISO '
    '8601 UTC timestamp string; select -> one of the declared option '
    'strings; multi_select -> a list of declared option strings; relation '
    '-> a list of "[[Title]]" or "[[Title|Alias]]" wikilink strings; url -> '
    'a string that parses as an absolute http(s) URL. A missing key or '
    'null means the property is unset. Property keys match '
    r'^[a-z][a-z0-9_]*$, at most 64 characters, and may not be one of the '
    'reserved keys id, title, path, version, created_at, updated_at, type, '
    'tags, source, properties, views.';

const Map<String, Object?> _kPropertyDefinitionSchema = {
  'type': 'object',
  'additionalProperties': {
    'type': 'object',
    'properties': {
      'type': {
        'type': 'string',
        'enum': [
          'text',
          'number',
          'checkbox',
          'date',
          'select',
          'multi_select',
          'relation',
          'url',
        ],
      },
      'label': {'type': 'string'},
      'options': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'database': {'type': 'string'},
    },
    'required': ['type'],
  },
};

const Map<String, Object?> _kViewsSchema = {
  'type': 'array',
  'items': {
    'type': 'object',
    'properties': {
      'name': {'type': 'string'},
      'type': {
        'type': 'string',
        'enum': ['table', 'list', 'board'],
      },
      'filter': {'type': 'object'},
      'sort': {'type': 'array'},
      'group_by': {'type': 'string'},
      'properties': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': ['name', 'type'],
  },
};

const Map<String, Object?> _kSourceSchema = {
  'type': 'object',
  'properties': {
    'folder': {'type': 'string'},
    'tag': {'type': 'string'},
    'include_subfolders': {'type': 'boolean'},
  },
};

Map<String, PropertyDefinition> _parsePropertyDefinitions(
  Map<String, Object?>? raw,
) {
  if (raw == null) return const {};
  return {
    for (final entry in raw.entries)
      entry.key: PropertyDefinition.fromJson(
        (entry.value! as Map).cast<String, dynamic>(),
      ),
  };
}

List<ViewDefinition> _parseViews(List<Object?>? raw) {
  if (raw == null) return const [];
  return [
    for (final v in raw)
      ViewDefinition.fromJson((v! as Map).cast<String, dynamic>()),
  ];
}

DatabaseSource? _parseSource(Map<String, Object?>? raw) =>
    raw == null ? null : DatabaseSource.fromJson(raw.cast<String, dynamic>());

/// Builds the `structuredContent` a database tool returns for a
/// definition, matching `GET /databases/{id}`'s shape.
Map<String, Object?> _definitionJson(StoredNote note) {
  final def = parseDatabaseDefinition(
    id: note.id,
    title: note.title,
    path: note.path,
    extra: note.extra,
    version: note.version,
    createdAt: note.createdAt,
    updatedAt: note.updatedAt,
  );
  return def.toJson();
}

McpTool _listDatabasesTool(DatabaseRegistry? registry, SearchIndex search) =>
    McpTool(
      name: 'list_databases',
      description: 'List every registered database (a note whose '
          'frontmatter has type: database), with its id, title, path, '
          'source, and row_count. Mirrors GET /databases.',
      inputSchema: const {
        'type': 'object',
        'properties': <String, Object?>{},
        'required': <String>[],
      },
      annotations: _readOnlyAnnotations('List databases'),
      requiresWrite: false,
      handler: (args, principal) async {
        final query = DatabaseQuery(search.rawDb);
        final defs = registry?.all ?? const <DatabaseDefinition>[];
        return toolOk({
          'items': [
            for (final def in defs)
              DatabaseSummary(
                id: def.id,
                title: def.title,
                path: def.path,
                source: def.source,
                rowCount: query.rowCount(
                  source: def.source,
                  excludeIds: [def.id],
                ),
              ).toJson(),
          ],
        });
      },
    );

McpTool _getDatabaseTool(DatabaseRegistry? registry) => McpTool(
      name: 'get_database',
      description: 'Fetch one database definition by id, including every '
          'declared property (with its type and, for select/multi_select, '
          'options) and view. Call this before create_row or '
          'update_properties to learn the schema. Mirrors '
          'GET /databases/{id}.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      annotations: _readOnlyAnnotations('Get database'),
      requiresWrite: false,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final def = registry?.get(id);
        if (def == null) return toolFail(ErrorCode.notFound.wire);
        return toolOk(def.toJson());
      },
    );

McpTool _createDatabaseTool(NoteWriteService writes) => McpTool(
      name: 'create_database',
      description: 'Create a new database: a note with type: database '
          'frontmatter declaring source, properties, and views. source '
          "defaults to the new note's own folder (with subfolders) when "
          'omitted. $_kEncodingTable',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'path': {'type': 'string'},
          'source': _kSourceSchema,
          'properties': _kPropertyDefinitionSchema,
          'views': _kViewsSchema,
          'content': {'type': 'string'},
        },
        'required': ['title'],
      },
      annotations: _writeAnnotations(
        'Create database',
        destructive: false,
        idempotent: false,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final title = _requiredString(args, 'title');
        if (title.trim().isEmpty) {
          return toolFail(
            kErrorValidationFailed,
            message: 'title must not be blank',
          );
        }
        final path = (args['path'] as String?) ?? '';
        final content = (args['content'] as String?) ?? '';
        final source = _parseSource(
              (args['source'] as Map?)?.cast<String, Object?>(),
            ) ??
            DatabaseSource.folder(path);
        final properties = _parsePropertyDefinitions(
          (args['properties'] as Map?)?.cast<String, Object?>(),
        );
        final views = _parseViews((args['views'] as List?)?.cast<Object?>());
        try {
          final note = await writes.createDatabase(
            title: title,
            actor: principal.actor,
            source: source,
            path: path,
            content: content,
            properties: properties,
            views: views,
          );
          return toolOk(_definitionJson(note));
        } on DefinitionValidationException catch (e) {
          return toolFail(
            kErrorValidationFailed,
            message: e.violations.join('; '),
          );
        } on PathConflictException {
          return toolFail(kErrorPathConflict);
        } on InvalidPathException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        } on FormatException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        }
      },
    );

McpTool _updateDatabaseTool(
  DatabaseRegistry? registry,
  NoteWriteService writes,
) =>
    McpTool(
      name: 'update_database',
      description: "Replace a database's source, properties, and/or views "
          'wholesale (each supplied section replaces the current one '
          'entirely), enforcing optimistic concurrency via version. '
          'Removing a property from properties does not delete its values '
          'from existing rows. $_kEncodingTable',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'version': {'type': 'integer'},
          'source': _kSourceSchema,
          'properties': _kPropertyDefinitionSchema,
          'views': _kViewsSchema,
        },
        'required': ['id', 'version'],
      },
      annotations: _writeAnnotations(
        'Update database',
        destructive: true,
        idempotent: true,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        if (registry?.get(id) == null) return toolFail(ErrorCode.notFound.wire);
        final version = args['version']! as int;
        final source = _parseSource(
          (args['source'] as Map?)?.cast<String, Object?>(),
        );
        final hasProperties = args.containsKey('properties');
        final properties = hasProperties
            ? _parsePropertyDefinitions(
                (args['properties'] as Map?)?.cast<String, Object?>(),
              )
            : null;
        final hasViews = args.containsKey('views');
        final views = hasViews
            ? _parseViews((args['views'] as List?)?.cast<Object?>())
            : null;
        try {
          final updated = await writes.updateDatabase(
            id: id,
            ifMatch: version,
            actor: principal.actor,
            source: source,
            properties: properties,
            views: views,
          );
          return toolOk(_definitionJson(updated));
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        } on DefinitionValidationException catch (e) {
          return toolFail(
            kErrorValidationFailed,
            message: e.violations.join('; '),
          );
        } on PathConflictException {
          return toolFail(kErrorPathConflict);
        } on FormatException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        } on VersionConflictException catch (e) {
          return _versionConflictFail(e.current, principal);
        }
      },
    );

/// Validates [filter] against [def]: every referenced property must be
/// declared (or a built-in) and the operator must be applicable to its
/// type, per the `databases` spec's "Filter expressions are structured,
/// not free text" requirement. Returns every violation found as a
/// human-readable string; an empty list means the filter is valid.
List<String> _validateQueryFilter(Filter filter, DatabaseDefinition def) {
  final errors = <String>[];
  void walk(Filter f) {
    switch (f) {
      case final Condition condition:
        final declared = def.properties[condition.property];
        final type = declared?.type ?? builtinPropertyType(condition.property);
        if (type == null) {
          errors.add('undeclared property "${condition.property}"');
          return;
        }
        if (!applicableFilterOps(type).contains(condition.op)) {
          errors.add(
            '${condition.op.wire} is not applicable to '
            '"${condition.property}"',
          );
        }
        if ((condition.op == FilterOp.isEmpty ||
                condition.op == FilterOp.isNotEmpty) &&
            condition.value != null) {
          errors.add('${condition.op.wire} takes no value');
        }
      case And(and: final children):
        for (final child in children) {
          walk(child);
        }
      case Or(or: final children):
        for (final child in children) {
          walk(child);
        }
    }
  }

  walk(filter);
  return errors;
}

/// Hydrates a raw [QueryRow] into the wire-shaped [DatabaseRow]: keeps only
/// [def]'s declared property keys that are present on the row, and flags
/// any of those whose stored value fails its declared type as `invalid`
/// (kept in `properties`, not dropped) per the spec's "Hand-edited invalid
/// value is reported, not dropped" scenario.
DatabaseRow _hydrateRow(
  QueryRow row,
  DatabaseDefinition def,
  MetaIndex metaIndex,
) {
  final properties = <String, Object?>{};
  final invalid = <String>[];
  for (final key in def.properties.keys) {
    if (!row.properties.containsKey(key)) continue;
    final value = row.properties[key];
    if (value == null) continue;
    properties[key] = value;
    if (validateProperties([def], {key: value}).isNotEmpty) {
      invalid.add(key);
    }
  }
  return DatabaseRow(
    id: row.id,
    title: row.title,
    path: row.path,
    version: metaIndex.get(row.id)?.version ?? 0,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    tags: row.tags,
    properties: properties,
    invalid: invalid,
  );
}

McpTool _queryDatabaseTool(
  DatabaseRegistry? registry,
  SearchIndex search,
  MetaIndex metaIndex,
) =>
    McpTool(
      name: 'query_database',
      description: "Query a database's rows: pick a saved view or pass "
          'filter/sort/group_by directly (a request field replaces the '
          "named view's corresponding field; the first declared view is "
          'the default when neither view nor a field is supplied). Returns '
          'rows with their declared properties plus group counts when '
          'group_by is in effect. $_kFilterGrammar Sort is a list of '
          '{"property","direction":"asc"|"desc"}, applied stably with id '
          'ascending as the final tie-break and unset values last either '
          'direction. Mirrors POST /databases/{id}/query.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'view': {'type': 'string'},
          'filter': {'type': 'object'},
          'sort': {'type': 'array'},
          'group_by': {'type': 'string'},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
          'after': {'type': 'string'},
        },
        'required': ['id'],
      },
      annotations: _readOnlyAnnotations('Query database'),
      requiresWrite: false,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final def = registry?.get(id);
        if (def == null) return toolFail(ErrorCode.notFound.wire);

        ViewDefinition? view;
        final viewName = args['view'] as String?;
        if (viewName != null) {
          for (final v in def.views) {
            if (v.name.toLowerCase() == viewName.toLowerCase()) view = v;
          }
          if (view == null) {
            return toolFail(
              kErrorValidationFailed,
              message: 'no view named "$viewName"',
            );
          }
        } else if (def.views.isNotEmpty) {
          view = def.views.first;
        }

        Filter? filter;
        try {
          final filterArg = args['filter'] as Map?;
          filter = filterArg != null
              ? Filter.fromJson(filterArg.cast<String, dynamic>())
              : view?.filter;

          List<SortSpec> sort;
          final sortArg = args['sort'] as List?;
          if (sortArg != null) {
            sort = [
              for (final s in sortArg)
                SortSpec.fromJson((s as Map).cast<String, dynamic>()),
            ];
          } else {
            sort = view?.sort ?? const [];
          }

          final groupBy = (args['group_by'] as String?) ?? view?.groupBy;

          if (filter != null) {
            final errors = _validateQueryFilter(filter, def);
            if (errors.isNotEmpty) {
              return toolFail(
                kErrorValidationFailed,
                message: errors.join('; '),
              );
            }
          }
          if (groupBy != null &&
              def.properties[groupBy] == null &&
              builtinPropertyType(groupBy) == null) {
            return toolFail(
              kErrorValidationFailed,
              message: 'undeclared property "$groupBy"',
            );
          }

          final groupProp = groupBy == null ? null : def.properties[groupBy];
          final page = DatabaseQuery(search.rawDb).run(
            source: def.source,
            filter: filter,
            sort: sort,
            groupBy: groupBy,
            groupByOptions: groupProp?.type == PropertyType.select
                ? groupProp!.options
                : null,
            limit: (args['limit'] as int?) ?? 50,
            after: args['after'] as String?,
            excludeIds: [id],
          );

          return toolOk(
            DatabaseQueryPage(
              items: [
                for (final row in page.items) _hydrateRow(row, def, metaIndex),
              ],
              nextCursor: page.nextCursor,
              groups: page.groups,
            ).toJson(),
          );
        } on FormatException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        } on InvalidCursorException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.reason);
        }
      },
    );

McpTool _createRowTool(NoteWriteService writes) => McpTool(
      name: 'create_row',
      description: 'Create a new row (note) in database id, validating '
          'properties against its declared schema before anything is '
          'written. For a folder source, path defaults to the source '
          'folder and must fall under it; for a tag source, path defaults '
          'to the vault root and the source tag is added automatically. '
          '$_kEncodingTable Mirrors POST /databases/{id}/rows.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'title': {'type': 'string'},
          'properties': {'type': 'object'},
          'content': {'type': 'string'},
          'path': {'type': 'string'},
        },
        'required': ['id', 'title'],
      },
      annotations: _writeAnnotations(
        'Create row',
        destructive: false,
        idempotent: false,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final title = _requiredString(args, 'title');
        if (title.trim().isEmpty) {
          return toolFail(
            kErrorValidationFailed,
            message: 'title must not be blank',
          );
        }
        final properties =
            (args['properties'] as Map?)?.cast<String, Object?>() ?? const {};
        final content = (args['content'] as String?) ?? '';
        final path = args['path'] as String?;
        try {
          final note = await writes.createRow(
            databaseId: id,
            title: title,
            actor: principal.actor,
            properties: properties,
            content: content,
            path: path,
          );
          return toolOk(_noteJson(note));
        } on DatabaseNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        } on PathOutsideSourceException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.toString());
        } on PropertyValidationException catch (e) {
          return toolFail(
            kErrorValidationFailed,
            message: e.violations.join('; '),
          );
        } on PathConflictException {
          return toolFail(kErrorPathConflict);
        } on InvalidPathException catch (e) {
          return toolFail(kErrorValidationFailed, message: e.message);
        }
      },
    );

McpTool _updatePropertiesTool(NoteWriteService writes) => McpTool(
      name: 'update_properties',
      description: 'Set and/or unset frontmatter property keys on a note '
          'without touching its body or requiring a version — the patch is '
          'serialised with every other write to the note, ignores the '
          'editor lock, and broadcasts a changed event. At least one of '
          'set or unset must be non-empty; a key in both is rejected. '
          '$_kEncodingTable Mirrors PATCH /notes/{id}/properties.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'set': {'type': 'object'},
          'unset': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['id'],
      },
      annotations: _writeAnnotations(
        'Update properties',
        destructive: true,
        idempotent: true,
      ),
      requiresWrite: true,
      handler: (args, principal) async {
        final id = _requiredNoteId(args);
        if (id == null) return toolFail(ErrorCode.notFound.wire);
        final set = (args['set'] as Map?)?.cast<String, Object?>() ?? const {};
        final unset =
            (args['unset'] as List?)?.cast<String>().toSet() ?? const {};
        try {
          final updated = await writes.patchProperties(
            id: id,
            set: set,
            unset: unset,
            actor: principal.actor,
          );
          return toolOk(_noteJson(updated));
        } on NoteNotFoundException {
          return toolFail(ErrorCode.notFound.wire);
        } on PropertyValidationException catch (e) {
          return toolFail(
            kErrorValidationFailed,
            message: e.violations.join('; '),
          );
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
  required String path,
  required int version,
  required DateTime createdAt,
  required DateTime updatedAt,
}) =>
    {
      'id': id,
      'title': title,
      'path': path,
      'version': version,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };

Map<String, Object?> _noteJson(StoredNote note) => {
      ..._summaryJson(
        id: note.id,
        title: note.title,
        path: note.path,
        version: note.version,
        createdAt: note.createdAt,
        updatedAt: note.updatedAt,
      ),
      'content': note.content,
      'properties': _propertiesOf(note),
      if (isDatabaseDefinitionExtra(note.extra)) 'type': 'database',
    };

/// The caller-visible property map for [note]: its frontmatter `extra`
/// with the storage-managed/server-interpreted keys excluded, per
/// `GET /notes/{id}`'s `properties` field.
Map<String, Object?> _propertiesOf(StoredNote note) => {
      for (final entry in note.extra.entries)
        if (!kServerInterpretedKeys.contains(entry.key)) entry.key: entry.value,
    };
