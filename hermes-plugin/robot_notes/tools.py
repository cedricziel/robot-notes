"""Tool schemas exposed to the model, plus the name -> handler-method-name table.

Kept out of ``__init__.py`` on purpose (#244): that module is edited concurrently by
several other in-flight changes to ``RobotNotesProvider``, and the schema block was
the largest, least-often-touched piece of it. ``TOOL_SCHEMAS`` is data
(``get_tool_schemas()`` returns it more or less as-is); ``TOOL_HANDLERS`` maps each
tool name to the ``RobotNotesProvider`` method that implements it, so
``handle_tool_call`` can dispatch with a plain ``getattr`` instead of a hand-rolled
list of ``{"name": ..., "handler": self._tool_x}`` dicts built in ``__init__``.

``_schema``/``_p`` follow the compact helper pattern from hermes-agent's bundled
RetainDB provider (``plugins/memory/retaindb/__init__.py``) — every parameter
documents itself instead of being a bare JSON-schema type.
"""

from __future__ import annotations

from typing import Any, Dict, Tuple


def _schema(name: str, description: str, properties: dict | None = None, required: tuple = ()) -> dict:
    return {
        "name": name,
        "description": description,
        "parameters": {"type": "object", "properties": properties or {}, "required": list(required)},
    }


def _p(description: str, type_: str = "string", **extra) -> dict:
    return {"type": type_, **extra, "description": description}


TOOL_SCHEMAS: Tuple[Dict[str, Any], ...] = (
    _schema(
        "robotnotes_search",
        "Search the shared robot-notes workspace. This is keyword full-text search, not "
        "a wildcard — there is no query that means \"every note\" (a query like '*' is "
        "rejected, and a generic term like 'notes' only matches notes that literally "
        "contain that word). To enumerate everything in the workspace, use "
        "robotnotes_list instead.",
        {
            "query": _p("Keyword(s) to search for."),
            "path": _p("Restrict the search to notes under this folder, e.g. 'Hermes'."),
            "limit": _p("Max results to return (default: 20).", "integer"),
        },
        ("query",),
    ),
    _schema(
        "robotnotes_list",
        "List every note's metadata (id, title, path, version, timestamps — no content) "
        "from the shared robot-notes workspace, optionally narrowed to a folder with "
        "'path'. Paginated: call again with 'after' set to the previous response's "
        "next_cursor until it comes back null to see the whole workspace. Use this "
        "instead of robotnotes_search to browse or enumerate everything.",
        {
            "path": _p("Only list notes under this folder, e.g. 'Hermes'."),
            "after": _p("Opaque page cursor from a previous response's next_cursor; omit for the first page."),
            "limit": _p("Max notes per page (default: 50).", "integer"),
        },
    ),
    _schema(
        "robotnotes_note",
        "Fetch a note from the shared robot-notes workspace by id.",
        {"id": _p("The note's id, as returned by search, list, or remember.")},
        ("id",),
    ),
    _schema(
        "robotnotes_remember",
        "Store a durable fact as a NEW note in the shared robot-notes workspace. Search "
        "first (robotnotes_search or robotnotes_list) — if a note on this topic already "
        "exists, call robotnotes_append instead of creating a duplicate. A title that "
        "already exists under 'path' is rejected with a path_conflict error; on that "
        "error, search for the existing note and append to it rather than retrying "
        "under a different title.",
        {
            "title": _p("Title for the new note. Must be unique within 'path'."),
            "content": _p("Body content for the new note."),
            "path": _p("Folder to file the note under, e.g. 'Hermes'. Defaults to the vault root."),
        },
        ("title", "content"),
    ),
    _schema(
        "robotnotes_append",
        "Append content to an existing note as a new line, without touching what's "
        "already there. Prefer this over robotnotes_remember once a relevant note "
        "exists — search before creating, and append rather than duplicating a note on "
        "the same topic.",
        {
            "id": _p("Id of the note to append to, as returned by search, list, or remember."),
            "content": _p("Text to append as a new line at the end of the note."),
        },
        ("id", "content"),
    ),
    _schema(
        "robotnotes_forget",
        "Delete a note this agent created from the shared robot-notes workspace.",
        {"id": _p("Id of the note to delete.")},
        ("id",),
    ),
)

# Tool name -> RobotNotesProvider method name that implements it. handle_tool_call
# resolves this with getattr(self, ...) rather than holding bound methods in a list
# built in __init__, so this table can be a flat, inspectable piece of data.
TOOL_HANDLERS: Dict[str, str] = {
    "robotnotes_search": "_tool_search",
    "robotnotes_list": "_tool_list",
    "robotnotes_note": "_tool_note",
    "robotnotes_remember": "_tool_remember",
    "robotnotes_append": "_tool_append",
    "robotnotes_forget": "_tool_forget",
}
