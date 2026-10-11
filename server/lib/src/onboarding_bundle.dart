import 'package:server/src/invite_store.dart';

/// Builds the onboarding-bundle plain-text payload returned by
/// `GET /invites/{token}/onboarding.txt`.
///
/// The bundle is a single Markdown-compatible document so an agent can
/// dump it straight into a system prompt or a notes file without
/// post-processing. It carries a scoped agent bearer key, the server's
/// public base URL, a recommended `X-Actor` derived from the invite
/// label, and a quick reference to the API surface.
String buildOnboardingBundle({
  required Invite invite,
  required String apiKey,
  required Uri baseUrl,
}) {
  final actor = onboardingActor(invite.label);
  final base = _trimSlash(baseUrl.toString());
  return '''
# robot-notes onboarding

You have been issued a single-use invite. This bundle was generated
once for token `${invite.token}` and will not be served again.

## Credentials

API key (Bearer): $apiKey
Recommended X-Actor: $actor
Server base URL: $base
ROBOT_NOTES_MCP_URL=$base/mcp

Send `Authorization: Bearer $apiKey` on every HTTP request and
your actor is recorded by the server when this credential is issued.

## MCP

If your agent host speaks MCP, connect it to $base/mcp instead of
calling the HTTP API by hand. The same API key works as the bearer
credential: send `Authorization: Bearer $apiKey` on
`POST $base/mcp`.

## API surface

### Notes (HTTP/JSON)
- GET    $base/notes                 list (paginated, ?after=<id>&limit=<n>)
- POST   $base/notes                 create — body `{"title":"...","content":"..."}`
- GET    $base/notes/{id}            read
- PUT    $base/notes/{id}            update — `If-Match: <version>` required
- DELETE $base/notes/{id}            delete

### Editor locks
- POST   $base/notes/{id}/lock       acquire (60s TTL)
- PUT    $base/notes/{id}/lock       heartbeat
- DELETE $base/notes/{id}/lock       release

### Search
- GET    $base/search?q=<fts>        FTS5 ranked search (limit defaults 20, max 100)

### Health
- GET    $base/healthz               liveness — does not require auth

### Real-time
- WS     ${base.replaceFirst(RegExp('^https?://'), 'ws://')}/ws

  Send `{"type":"auth","key":"$apiKey","actor":"$actor"}` as the first
  frame. Subscribe with `{"type":"subscribe","note":"<id>"}` (or `"*"`)
  to receive `presence`, `lock`, and `changed` events. Reply to
  server-issued `ping` frames with `pong`.

## Notes
- The server is single-tenant. One server = one workspace.
- Your credential records your actor and permitted vaults. Actor headers cannot change your identity.
- This credential does not grant operator administration. Curated knowledge proposal authority does not grant review, accepted-edit, policy, or purge authority.
- This token is now burned; refetching this URL returns 410 Gone.
''';
}

/// Lower-cases [label], replaces non-alphanumeric runs with `-`, trims
/// surrounding `-`, and falls back to `agent` if the result is empty.
String onboardingActor(String label) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'agent' : slug;
}

String _trimSlash(String s) =>
    s.endsWith('/') ? s.substring(0, s.length - 1) : s;
