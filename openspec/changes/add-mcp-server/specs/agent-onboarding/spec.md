## ADDED Requirements

### Requirement: Onboarding bundle advertises the MCP endpoint

The onboarding bundle SHALL include a `ROBOT_NOTES_MCP_URL=<base>/mcp` line alongside the existing `ROBOT_NOTES_*` lines, and its inline guide SHALL state that the same API key works as the bearer credential for `POST <base>/mcp`.

#### Scenario: Bundle names the MCP URL

- **WHEN** an agent fetches a valid `GET /invites/{token}/onboarding.txt`
- **THEN** the body SHALL contain a line `ROBOT_NOTES_MCP_URL=<base>/mcp` and the text `/mcp`
