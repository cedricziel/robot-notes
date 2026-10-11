## Identity and storage

The configured operator key authenticates as `operator`. OAuth tokens authenticate as `oauth:<grant_id>`; rotation keeps the grant ID. Scoped secrets authenticate as `agent:<credential_id>`. Actor names remain attribution. Agent and OAuth credentials ignore caller actor claims.

Store agent records under `<data_dir>/credentials`, outside note content and search indexes. Each record contains an immutable random identity, SHA-256 secret digest, actor, scope set, vault IDs, issuance time, and optional revocation time. Return a 256-bit bearer secret once at provisioning. Listings contain neither the secret nor its digest. Revocation persists before disconnecting active agent WebSockets.

## Provisioning

Only the operator may use `GET /credentials`, `POST /credentials`, `DELETE /credentials/{id}`, or administer invites. Provisioning accepts explicit scopes and existing vault IDs; omitted permissions default to notes read/write and knowledge propose in the default vault. Operator provisioning may explicitly grant knowledge review, edit, policy, or purge. OAuth grants request those same capabilities through consent. Omitted OAuth scopes continue to mean notes read/write.

An invite remains a single-use capability. Redemption burns it before issuing a new default agent credential. Failure or a lost response requires a replacement invite; no raw secret is persisted for retrieval. The invite never distributes the operator key.

## Adapter enforcement and limits

REST checks method scopes and selected vaults. MCP checks tool scopes and vaults. WebSockets require notes read in their selected vault and disconnect when their credential is revoked. All three use recorded caller identity. Knowledge capability grants alone do not implement curated note policy; #369 must enforce them in content and review services before enabling curated notes.

Existing holders of the operator key retain administration. The server cannot infer which root callers are humans or agents. Migration requires issuing new credentials, changing agent configuration, rotating the shared operator key, and updating operator clients.

Elevated knowledge scopes require operator-key consent even when OIDC sign-in is configured. OIDC sign-in alone can grant proposal authority but cannot provision review, accepted-edit, policy, or purge authority.
