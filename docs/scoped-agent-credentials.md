# Scoped agent credentials

Agent invites now issue a separate server-recorded credential. The default credential can read and write ordinary notes in the default vault and carries `knowledge:propose`. It has no review, accepted-edit, policy-management, purge, or vault-management authority. Curated knowledge policy enforcement is a separate feature; a knowledge scope does not create a proposal endpoint or a curated note policy.

Use the operator key to create an agent credential:

```sh
curl -X POST "$ROBOT_NOTES_URL/credentials" \
  -H "Authorization: Bearer $ROBOT_NOTES_OPERATOR_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"actor":"research-agent","scopes":["notes:read","notes:write","knowledge:propose"],"vault_ids":["default"]}'
```

The response includes `id` and `secret`. Save the secret in the agent's credential configuration. The server returns it once and persists only its SHA-256 digest. The same secret works for REST, MCP, and WebSockets. The recorded actor overrides any actor header or WebSocket actor claim.

The operator can list credentials with `GET /credentials`. To revoke one, call `DELETE /credentials/{id}`. Revocation persists across restarts and disconnects existing agent WebSocket connections. Vault IDs must already exist when the operator provisions a credential. Ordinary notes access still requires the relevant `notes:read` or `notes:write` scope.

OAuth clients can request `knowledge:propose`, `knowledge:review`, `knowledge:edit`, `knowledge:policy`, and `knowledge:purge` explicitly at consent. Omitted OAuth scopes remain `notes:read notes:write`. Refresh preserves the grant's identity and does not add capabilities.

## Migrate existing agents

Existing agents that received the operator key retain operator administration. The server cannot identify or downgrade them automatically.

1. Create a scoped credential for each agent, or redeem a new invite for its default credential.
2. Replace the agent's bearer key in its host configuration or secret store. Configure its allowed vault IDs when provisioning.
3. Verify that the agent can access its intended ordinary notes and cannot administer invites or credentials.
4. Generate and configure a new operator key using the server's `ROBOT_NOTES_API_KEY` setting, then restart the server.
5. Update operator clients with the new key. Previously distributed operator keys are no longer accepted.

Credential records are stored under the server data directory's `credentials` folder. Include that folder in backups and restrict filesystem access as you do for OAuth token records.

Elevated knowledge scopes require operator-key consent even when OIDC sign-in is configured. OIDC sign-in alone can grant proposal authority but cannot provision review, accepted-edit, policy, or purge authority.
