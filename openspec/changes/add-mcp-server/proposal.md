## Why

Agents today reach robot-notes only through the raw HTTP API and a shared static key. Every agent host that speaks MCP (desktop assistants, IDE agents, hosted agents) can already connect to a remote MCP server by URL and self-register via OAuth Dynamic Client Registration, but robot-notes offers no such endpoint. Exposing the notes as an MCP server with a built-in OAuth flow lets any user point any agent at the server and use the workspace as shared memory, without copying the API key around.

## What Changes

- **NEW** Streamable HTTP MCP endpoint at `POST /mcp` exposing the note workspace as tools: `list_notes`, `get_note`, `create_note`, `update_note`, `append_to_note`, `delete_note`, `search_notes`
- **NEW** Built-in OAuth 2.1 authorization server: protected-resource metadata, authorization-server metadata, Dynamic Client Registration (`POST /oauth/register`), authorization-code + PKCE flow with a browser consent page, token endpoint with refresh-token rotation, and revocation
- **NEW** Consent page authenticates the resource owner with the existing bearer API key and captures the actor name the agent will write under
- **NEW** OAuth clients, codes, and hashed tokens persisted under `<data-dir>/oauth/` so agent connections survive server restarts
- **NEW** `/mcp` accepts either an OAuth access token or the static bearer key, so invite-onboarded agents can use MCP too
- **NEW** Optional `--public-url` / `ROBOT_NOTES_PUBLIC_URL` config pinning the absolute origin used in OAuth metadata behind reverse proxies
- **NEW** Onboarding bundle advertises the MCP endpoint
- **MODIFIED** The auth spec's blanket "any path containing `/auth` returns 404" rule is narrowed to key-rotation paths, since `/oauth/authorize` now exists

## Capabilities

### New Capabilities

- `mcp-server`: Streamable HTTP MCP endpoint, JSON-RPC lifecycle, tool catalog and tool semantics, protocol-version and origin handling
- `oauth-authorization`: OAuth 2.1 resource-server metadata, authorization-server metadata, Dynamic Client Registration, authorization-code + PKCE flow, token issuance, refresh rotation, revocation, and token persistence

### Modified Capabilities

- `auth`: "Bearer key rotation requires a server restart" scenario no longer claims every `/auth*` path is 404; `/mcp` additionally accepts OAuth access tokens; new unauthenticated OAuth discovery/registration/authorize/token paths are exempt from the static bearer check
- `agent-onboarding`: onboarding bundle lists the MCP endpoint alongside the HTTP routes

## Non-goals

- MCP resources, prompts, sampling, elicitation, or server-initiated SSE streams (tools only, stateless JSON responses)
- Multi-user accounts, per-user permissions, or per-client ACLs (one workspace, one owner)
- Token introspection endpoint, JWT access tokens, or external identity providers
- Rate limiting or lockout on the consent form (same exposure as the existing bearer check; tracked as follow-up)
- Stdio transport
- Flutter UI for managing OAuth clients or tokens
- Backwards-compatible HTTP+SSE (2024-11-05) transport

## Impact

- `server/`: new routes (`/mcp`, `/oauth/*`, `/.well-known/*`), new stores under `lib/src/oauth/` and `lib/src/mcp/`, auth middleware exemptions, static-web passthrough prefixes, `Config` gains `publicUrl`
- `shared/`: route constants for the new paths
- Dependencies: `crypto` (SHA-256 for PKCE and token hashing) promoted to a direct server dependency; no MCP SDK dependency
- Docs: README and `server/API.md` gain an "Connecting an MCP client" section
- No storage format changes to notes; `<data-dir>/oauth/` is additive
