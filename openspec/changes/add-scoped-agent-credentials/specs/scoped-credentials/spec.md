## ADDED Requirements

### Requirement: Recorded credential identity
The server SHALL bind authenticated requests to the operator identity, a stable OAuth grant ID, or a stable server-issued credential ID. Display actor headers SHALL NOT establish credential identity or approval authority.

#### Scenario: An agent claims to be the operator
- **WHEN** an agent credential supplies an operator actor header or WebSocket actor value
- **THEN** the server uses the credential record for identity and attribution

### Requirement: Scoped agent onboarding
Invite redemption SHALL issue a unique default-vault credential with notes read/write and knowledge proposal authority. It SHALL NOT reveal the configured operator key or grant review, accepted-edit, policy, purge, or vault-management authority.

#### Scenario: An invite is redeemed concurrently
- **WHEN** several callers redeem one unexpired invite
- **THEN** exactly one receives a scoped bearer secret and later callers receive the burned response

### Requirement: Operator credential administration
Only the configured operator key SHALL provision, list, and revoke agent credentials or administer invites. Credential listings SHALL NOT include raw secrets or their digests. Revocation SHALL reject future REST, MCP, and WebSocket authentication and disconnect live agent WebSockets.

#### Scenario: A write-authorized agent attempts delegation
- **WHEN** the agent tries to mint an invite or another credential
- **THEN** the server denies the request

### Requirement: Explicit capability grants
Knowledge propose, review, edit, policy, and purge SHALL be distinct explicit scopes. Existing OAuth grants and omitted-scope defaults SHALL NOT gain knowledge permissions. Credential and OAuth vault grants SHALL apply to all adapters.

#### Scenario: A caller requests review permission through OIDC alone
- **WHEN** the caller requests an elevated knowledge scope through the OIDC login or callback flow
- **THEN** the server denies the grant and requires operator-key approval

#### Scenario: A consented review token is refreshed
- **WHEN** a token with explicitly granted knowledge review is refreshed
- **THEN** its stable principal ID and granted scopes remain unchanged
