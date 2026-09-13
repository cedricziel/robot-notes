# Connecting a new MCP client to robot-notes

This only applies when setting up a _new_ connection to a robot-notes
server. A client that already lists the robot-notes tools is already
connected — skip this file.

The server exposes the note workspace as a stateless MCP (Streamable
HTTP) endpoint at `<base>/mcp`, e.g. `https://notes.example.com/mcp`.

## Two auth paths, same endpoint

**OAuth (hosted/desktop MCP clients):** the client discovers OAuth
endpoints from `/.well-known/oauth-protected-resource` and
`/.well-known/oauth-authorization-server`, registers itself via Dynamic
Client Registration (`POST /oauth/register`), and opens a browser
consent page. That page asks the person completing setup for the
workspace API key (proof they're allowed to grant access) and a display
name — the actor every note the agent writes will be attributed to.
Approving it exchanges an authorization code at `POST /oauth/token` for
an access token scoped to `notes:read` and/or `notes:write`.

**Static key (agents onboarded via an invite):** skip OAuth and call
`/mcp` directly with:

```
Authorization: Bearer <api-key>
X-Actor: <name>
```

Both paths are accepted on the same endpoint and coexist.

## MCP-specific response quirks

- An unauthenticated `GET` or `DELETE` on `/mcp` returns `401` rather
  than `405` — the credential is checked before the method.
- A request whose `Origin` header doesn't match the server's own origin
  (or a loopback origin) returns `403 forbidden`.
- A request naming an `MCP-Protocol-Version` the server doesn't
  understand returns `400 unsupported_protocol_version`.

## Scopes

An OAuth grant's scopes gate the six write tools
(`create_note`, `update_note`, `append_to_note`, `delete_note`,
`move_note`, `create_folder`) separately from the four read tools
(`list_notes`, `get_note`, `search_notes`, `get_backlinks`). The static
API key always holds both scopes.

## Security

Run the server behind HTTPS in any deployment reachable over an
untrusted network — the OAuth consent form submits the workspace API key
over that connection, with the same exposure as the bearer check
everywhere else in the API.

Full invite lifecycle (issuing, consuming, revoking onboarding
credentials) is documented in the repo's `RELEASING.md` under
"Operating agent onboarding invites".
