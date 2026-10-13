# Background knowledge extraction configuration

Robot Notes can extract durable knowledge from retained sources and submit typed
proposals for human review. The server runs the extraction worker and calls the configured model. Hermes
captures sources through its turn and session hooks. The bundled skill guides
proposals made by the conversational agent; the server does not execute that skill.

## Server settings

Knowledge services are disabled by default. Set these server environment variables
to activate the services and configure the model:

```sh
ROBOT_NOTES_KNOWLEDGE_ENABLED=true
ROBOT_NOTES_EXTRACTION_ENDPOINT=https://your-provider.example/v1
ROBOT_NOTES_EXTRACTION_MODEL=your-model
ROBOT_NOTES_EXTRACTION_API_KEY=your-server-secret
```

The endpoint is an OpenAI-compatible API base URL. The worker sends requests to
`chat/completions` and requests JSON output. The API key remains in server
configuration and is excluded from persisted job configuration and diagnostics.
Setting the endpoint, model, and key does not enable extraction for any source scope.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `ROBOT_NOTES_EXTRACTION_MAX_INPUT` | `16000` | Source characters per model request, counted as Unicode scalars |
| `ROBOT_NOTES_EXTRACTION_MAX_CANDIDATES` | `10` | Findings per model request |
| `ROBOT_NOTES_EXTRACTION_MAX_CHUNKS` | `16` | Model requests per job |
| `ROBOT_NOTES_EXTRACTION_MAX_ATTEMPTS` | `3` | Attempts before a transient failure remains blocked |
| `ROBOT_NOTES_EXTRACTION_TIMEOUT_SECONDS` | `45` | Timeout per model request |
| `ROBOT_NOTES_EXTRACTION_TOKEN_PARAMETER` | `max_completion_tokens` | Set to `max_tokens` for providers that require that spelling |

## Source scope and Hermes settings

Accept the required type definitions before extracting knowledge. Schema.org
adoption and the initial local types are reviewed through the knowledge type
proposal operations.

Use `configure_source_scope` with human policy authority to configure capture
adapters, permitted principals, `extraction_enabled`, and `trigger`. Valid triggers
are `session_end`, `completed_turn`, and `both`; the default is `session_end`.
Capture and extraction have separate opt-ins.

In `$HERMES_HOME/robot_notes.json`, configure:

```json
{
  "source_capture": true,
  "source_scope_id": "your-configured-scope"
}
```

Hermes queues observations from `sync_turn()` and `on_session_end()` in a bounded
local SQLite outbox. Only the primary conversation captures sources. The server
decides which observations qualify for extraction using the scope settings.
Evidence archive settings are independent of source capture.

## Review and diagnostics

The worker reads source passages, compares authorized accepted knowledge and
pending proposals, classifies findings, and proposes atomic groups. Classifications
are `new`, `update`, `disputed`, and `no_material`. Evidence references an immutable
source revision and a verified passage. Automatically captured assistant output
alone cannot support an extracted claim.

Use `extraction_health` to inspect job states, safe diagnostic categories, proposal
receipts, and the next source offset. Model requests have no tools or review
authority. Accepted queries exclude pending proposals and raw sources. A human
must approve a proposal before its text becomes accepted knowledge.

Use `reextract_source` with human policy authority to explicitly replay a retained
source revision. Supply a distinct `generation` such as `manual-1`; retrying that
generation recovers the same job identity. Extraction must be enabled for the scope,
and the originating principal must still have access. An unchanged accepted or
pending finding does not create another proposal.

The REST capability endpoint is `GET /knowledge/capabilities`. Operations use
`POST /knowledge/operations/<operation>` and are also exposed as MCP tools when
knowledge services are enabled. The existing vault selection and credential
permissions apply to these operations.


## Retained sources

`inspect_source` returns an authorized descriptor and a `blob_ref` containing the
selected vault and download URL. `GET /knowledge/sources/<source_id>/<revision>`
returns the original bytes as an attachment. Download requests use the same
credential and vault headers as the other REST operations. Missing and unreadable
revisions return the same response.

`purge_source_revision` requires source purge authority. It removes the retained
bytes and cancels affected unsubmitted extraction work. Accepted knowledge and
proposal history follow their own retention and review rules; source erasure does
not silently rewrite accepted claims.

## Verification

The isolated release verification used the pinned real Hermes `MemoryManager`,
a disposable server, and a deterministic local model endpoint. `both` produced
two completed jobs and one pending proposal containing an Evidence and a Claim.
The accepted query remained empty until human approval, then returned both entries.
Separate runs verified one eligible job each for `session_end` and `completed_turn`.
The source fixture included Unicode before the cited passage to check locator
handling. The Flutter web app displayed the approved Claim and supporting passage.

See the project-local [verification workflow](../.agents/skills/verify-project-local/SKILL.md)
for isolation, app checks, and cleanup. Model output quality depends on the
configured provider; the deterministic fixture verifies the integration and review
boundary rather than extraction accuracy across arbitrary sources.
