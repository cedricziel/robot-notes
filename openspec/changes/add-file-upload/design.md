## Context

See proposal.md - Why. `maxUploadSizeBytes` (config) and the sanitize/collision/atomic-write logic (currently `AttachmentStore`, being renamed `FileStore`) already merged from the original proposal and are reused unchanged here — this design only revises how bytes get _to_ that write path, and how a written file becomes _discoverable_ afterward.

`InviteStore` (`server/lib/src/invite_store.dart`) is the existing precedent for "mint an opaque token, track its expiry, consume it once": `KeyedMutex`/`isSafeStoreKey`/`atomicWriteJsonFile` (`server/lib/src/oauth/store_support.dart`) are reused infrastructure, not new concepts.

## Goals / Non-Goals

**Goals:**

- An MCP-driven agent can place a file of any realistic size into the vault without embedding its bytes in a JSON-RPC tool call.
- A file, once uploaded by either path, is discoverable by browsing (folder tree, folder listing) — not only retrievable if the exact path is already known.
- The two upload entry points (direct multipart, two-phase token) share one write implementation, so sanitization/collision/size-limit invariants only need to be correct once.

**Non-Goals:**

- No resumable/chunked upload — a `PUT` that's interrupted mid-transfer just fails; the caller calls `request_upload` again for a fresh token.
- No persistence of upload-session state across a server restart — a session is expected to complete within its TTL (minutes), so losing in-flight (never-finalized) sessions on restart is an acceptable trade for not needing atomic-JSON-file machinery for something this short-lived. (The underlying vault file store itself remains fully durable, as always.)
- No full pagination machinery for file listings — a folder's files are returned as a flat, unpaginated list. A vault folder holding thousands of loose files is not a case this needs to optimize for; notes already have proper pagination for the case that matters.

## Decisions

### The two-phase flow is three MCP-visible steps, but only one new route

**Decision:** `request_upload` and `finalize_upload` are the only new MCP surface. The byte transfer itself (`PUT /notes/file-uploads/{token}`) is a REST route, not a JSON-RPC call — it has to be, since that's the entire point (raw bytes, not JSON). `request_upload` doesn't need a REST equivalent: it's a plain in-process call (mint a token, record a session) that the MCP handler can make directly since it lives in the same server.

**Why:** Minimal new surface for the minimal new problem. A direct HTTP client (the Flutter app) never needs `request_upload`/`finalize_upload` at all — it already has real bytes and stays on the one-shot `POST /notes/files`.

**Alternatives considered:**

- _Expose `request_upload`/`finalize_upload` as REST routes too, for symmetry._ Rejected for now: no current caller needs it, and it's easy to add later if a non-MCP client turns out to want the same two-phase flow (e.g. a future resumable-upload web client).

### The upload-session token is the sole authentication for the PUT step

**Decision:** `PUT /notes/file-uploads/{token}` does **not** require the normal `Authorization: Bearer <api-key>` header. The token itself — 16 bytes of secure randomness, single-use, short TTL, scoped to one `path`+`filename` pair chosen at `request_upload` time — is the credential, exactly like a cloud-storage presigned URL.

**Why:** The whole reason this flow exists is to let something other than the LLM-driven agent (a bare `curl`, the agent's host process) perform the byte transfer. Requiring the main API key there too would mean that process needs the same credential as the agent, defeating the "narrow, expiring, single-purpose" property a presigned URL is supposed to have.

**Alternatives considered:**

- _Require both the token and the bearer key._ Rejected: doesn't add meaningful defense here (the token is already unguessable and single-use) and forces the byte-transfer step to carry the same broad credential as everything else, which is exactly what a scoped token is meant to avoid.

### Upload sessions live in memory; staged bytes live on disk outside the vault

**Decision:** `UploadSessionStore` tracks `{token → path, filename, maxBytes, status, expiresAt, size?, contentType?}` in a plain in-memory map (see Non-Goals above). The staged bytes from a completed `PUT` are written to `<dataDir>/uploads/<token>.bin` — a sibling of `<dataDir>/content/` (the vault root), never inside it, so a staged-but-not-yet-finalized file can never be scanned, indexed, or served as a vault file by anything.

**Why:** Keeping staging physically outside `contentDir` means the "files are indexed by scanning `contentDir`" mechanism (see below) needs zero special-casing to avoid picking up in-flight uploads — they're simply never in the directory it walks.

### finalize_upload reuses FileStore.write; no separate placement logic

**Decision:** `finalize_upload` opens the staged `.bin` file as a byte stream and calls the exact same `FileStore.write(path, filename, bytes, maxBytes, contentType)` that `POST /notes/files` calls — sanitization, the collision check, and the atomic tmp+rename all happen exactly once, in one place, regardless of which upload path produced the bytes. A collision discovered only at finalize time (the target was claimed by something else between `request_upload` and now) surfaces as the same `path_conflict` error either route already uses; the session and its staged file are deleted either way — a rejected finalize doesn't leave a stale reservation.

**Why:** Two independent "place a file in the vault" implementations would be two places to keep collision/sanitization/atomicity correct. This mirrors the original proposal's decision to route the old `upload_file` tool through the same write helper `POST /notes/attachments` used — same reasoning, same shape.

### Files are indexed the same lightweight way empty-folder markers are

**Decision:** `Storage._scanAll()`, while it walks `contentDir` looking for `.md` notes and `.folder` markers, also collects every other regular file it encounters (excluding anything ending in `.tmp`, the in-progress-write suffix) into a small tracked set: relative path, size, and modified time. `Storage.filesIn(folderPath)` returns the direct (non-recursive) file children of a folder from that set. `GET /notes/tree`'s folder-discovery union (currently: folders holding a note ∪ folders holding an empty-folder marker) gains a third term: folders holding at least one file, with a `file_count` alongside the existing `note_count`.

**Why:** This is deliberately the same shape as the empty-folder-marker tracking already in `Storage` — a plain in-memory set rebuilt on scan, not a second `MetaIndex`-grade paginated structure. Files don't need id-based lookup, title resolution, tag filtering, or cursor pagination the way notes do; giving them the full `MetaIndex` treatment would be building for a scale and a set of operations nothing here actually needs yet (see Non-Goals).

**Alternatives considered:**

- _Fold files into `MetaIndex` as a new summary type alongside `NoteSummary`._ Rejected as more machinery than the stated goal (folder discoverability, a flat per-folder listing) requires; revisit if a future requirement needs file search, tagging, or cross-folder pagination.

### GET /notes/files?path= is a flat, unpaginated listing

**Decision:** `GET /notes/files?path=<folder>` returns every file directly in `<folder>` (not recursive into subfolders) as `{ items: [{ path, filename, size, content_type, updated_at }] }`, with no `next_cursor` / `after` / `limit` — the whole set, every time.

**Why:** See Non-Goals — this isn't the note-listing use case pagination exists for. Content-type here is resolved the same way `GET /notes/files/{path}` resolves it for retrieval (extension-based lookup), for consistency between "browsing" and "fetching."

## Risks / Trade-offs

- **[Risk]** An abandoned upload session (client called `request_upload`, never `PUT` or `finalize`d) leaves a staged `.bin` file and an in-memory entry until the TTL sweep runs. → **Mitigation:** short TTL (15 minutes), a periodic sweep inside `UploadSessionStore` that evicts expired sessions and deletes their staged files, plus a lazy expiry check on every access (`PUT`, `finalize_upload`) so an expired session is never usable even between sweeps.
- **[Risk]** A server restart mid-flight orphans any `<dataDir>/uploads/*.bin` file whose in-memory session was lost. → **Mitigation:** accepted (see Non-Goals) — these are small, rare, and don't affect the vault's actual content; a future pass could add a startup sweep of `<dataDir>/uploads/` by file age if this proves to matter in practice.
- **[Risk]** The token-only-auth `PUT` route is technically reachable by anyone who obtains the token (e.g. from a proxy log). → **Mitigation:** same threat model as any presigned URL — short TTL, single-use, scoped to a specific path+filename chosen by an already-authenticated `request_upload` call. This is a deliberate, standard trade-off, not an oversight.

## Migration Plan

No migration needed: purely additive on top of what already merged (`maxUploadSizeBytes`, the sanitize/collision/atomic-write helper). Renaming `AttachmentStore` → `FileStore` and the route paths (`/notes/attachments` → `/notes/files`) has no external callers yet — nothing shipped depending on the old names.
