## Context

See proposal.md - Why. The vault today has exactly two kinds of on-disk artifact: note `.md` files and (once `add-empty-folder-creation` lands) empty-folder `.folder` markers, both discovered by `Storage`'s single recursive scan of `content/`. `note_path.dart` already provides NFC normalization, illegal-character stripping, and a case-insensitive `collisionKey` used by every existing path-collision check. `dart_frog`'s `Request` type (the framework this server is built on) has a built-in `formData()` parser that decodes `multipart/form-data` into fields and `UploadedFile`s (name, content-type, byte stream) with no extra dependency — this change reuses it rather than adding `shelf_multipart` or similar.

## Goals / Non-Goals

**Goals:**

- An attachment can be uploaded to any folder and retrieved later, surviving a restart, with the same path-safety guarantees a note already has.
- Reuse the existing sanitization/collision primitives so an attachment's path/filename rules are identical to a note's.
- Keep the upload path memory-safe: a request over the configured size limit must not be fully buffered before being rejected.

**Non-Goals:**

- No new persisted metadata (a database row, a JSON sidecar) — the file on disk, discovered by the existing startup scan, is the only state.
- No change to `MetaIndex`'s data model — attachments are invisible to it entirely, unlike empty folders which get a small tracked set.

## Decisions

### Reuse dart_frog's built-in `formData()`, no new server multipart dependency

**Decision:** Parse the upload via `context.request.formData()`, which returns a `FormData` with `fields` (a `Map<String, String>`, giving us `path`) and `files` (a `Map<String, UploadedFile>`, giving us the upload by field name `file`). `UploadedFile.openRead()` exposes the byte stream without buffering it all into memory up front.

**Why:** The framework already ships this; adding `shelf_multipart` or hand-rolling a `MimeMultipartTransformer` pipeline would duplicate what's already available and tested, for no behavioral benefit.

**Alternatives considered:**

- _`shelf_multipart` directly._ Rejected: `dart_frog`'s `Request.formData()` already wraps the same underlying `mime` package; going around it would mean bypassing the framework's own request body handling.

### Size limit is enforced while streaming, not only via `Content-Length`

**Decision:** Check the `Content-Length` header against the configured max as a fast pre-check (reject immediately if it already exceeds the limit), and additionally count bytes while consuming `UploadedFile.openRead()`, aborting the write and deleting any partial temp file the moment the running total exceeds the limit — the same tmp+fsync+rename pattern notes already use, so a rejected upload never leaves a partial file at the final path.

**Why:** `Content-Length` is client-supplied and not authoritative (a chunked or lying request could omit or misstate it); the streaming counter is what actually bounds memory and disk usage regardless of what the header claims.

**Alternatives considered:**

- _Trust `Content-Length` alone._ Rejected: not a real bound — nothing stops a client from streaming more bytes than it declared.

### Attachment path resolution reuses `Storage`'s folder/collision logic, but attachments are not routed through `Storage`'s note-shaped API

**Decision:** Introduce a small sibling helper (not a new public method on `Storage`, to avoid stretching a note-shaped class over a different kind of artifact) that: sanitizes `path` via `sanitizedPathSegments` (the same helper `Storage.createFolder` uses), sanitizes the filename via `sanitizeFilenameSegment`/`normalizeToNfc` (the same helpers a note's title goes through), and checks the resulting `<path>/<filename>` against `collisionKey` — treating a hit against either an existing note file, an existing attachment, or an empty-folder marker as a collision, matching the requirement that any of the three block an upload.

**Why:** The path/filename rules must be identical to a note's for the "no path traversal, no illegal characters" guarantee to hold uniformly, but an attachment has no frontmatter, no id, no version, and isn't indexed — bolting it onto `Storage`'s note-oriented `create`/`update` API would mean threading a lot of note-only concepts through code that doesn't need them.

**Alternatives considered:**

- _Add `Storage.createAttachment(...)` alongside `createFolder`._ Considered reasonable and not strongly rejected — during implementation, if the sanitization/collision logic ends up small enough, it may simply live as a method on `Storage` after all rather than a separate helper. This is left as an implementation-time call, not a spec-level concern (see proposal.md's "Quick test" framing: this decision doesn't change any observable behavior).

### GET route uses a catch-all path segment

**Decision:** `GET /notes/attachments/{path}` is served by a single dart_frog catch-all route (`routes/notes/attachments/[...path].dart`) so a nested attachment path (`Projects/Alpha/diagram.png`) resolves in one route rather than needing per-depth route files. `POST /notes/attachments` (no trailing path — the target folder is a form field, not part of the URL) is a separate, sibling route file (`routes/notes/attachments/index.dart`).

**Why:** Mirrors how `GET /notes/{id}` already uses a dynamic segment (`routes/notes/[id]/index.dart`); a catch-all is the natural extension for a path that can be arbitrarily deep, and splitting POST (index) from GET (catch-all) avoids one handler having to distinguish "am I being POSTed to with a form body, or GETed with a path" in the same file.

**Alternatives considered:**

- _A single query-parameter-based endpoint (`GET /notes/attachments?path=...`)._ Rejected: every other path-addressed resource in this API (`GET /notes/{id}`) uses the path itself as the address; a query param here would be an inconsistent one-off.

### Content-Type on download is derived from the file extension, not stored

**Decision:** `GET /notes/attachments/{path}` resolves the response `Content-Type` from the requested filename's extension at read time (via the same `mime` package dart_frog already depends on transitively), rather than persisting the upload's declared content-type anywhere.

**Why:** No new metadata store means nothing to keep in sync; an extension-based lookup is deterministic and matches what every static file server already does. The upload response still echoes back the declared content-type for the client's immediate use (e.g. showing what it thinks it uploaded), but that's not authoritative for later downloads.

## Risks / Trade-offs

- **[Risk]** A very large upload could still exhaust memory if `UploadedFile.readAsBytes()` (which buffers into a single `List<int>`) is used instead of streaming to disk incrementally. → **Mitigation:** write via `openRead()` chunk-by-chunk into the tmp file, counting bytes per chunk, not via `readAsBytes()`.
- **[Risk]** Two concurrent uploads to the same target path could both pass the collision check before either writes. → **Mitigation:** reuse the same per-target-path mutex `Storage` already uses for note create/rename races, keyed by the attachment's collision key.
- **[Risk]** An attacker-controlled filename could still attempt path traversal or an overlong name. → **Mitigation:** identical sanitization to note titles already defends against this; no new attack surface beyond what note creation already handles.

## Migration Plan

No migration needed: purely additive. A vault with no uploaded attachments behaves exactly as today. No changes to note files, frontmatter, or the search/link/tag indices.
