## Why

The knowledge inbox uses different review routes for new and existing notes. Reviewers must leave the proposal context to comment or request changes, and the inbox does not use the app's shared states and platform controls.

## What Changes

- Show the proposal list beside the selected review on wide windows and a full-page review on narrow windows.
- Open each proposal directly with verified accepted targets, proposed changes, evidence, and discussion.
- Keep comments and decisions inline, with pending feedback and recoverable errors.
- Use the app's theme, adaptive controls, and shared empty and error states.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `flutter-client`: Add a responsive, unified proposal review workflow.

## Impact

Flutter knowledge inbox, proposal review presentation, and widget tests. Existing API permissions, revision checks, and accepted-content verification remain required. No new dependencies.

## Non-goals

No server changes, policy editing redesign, history redesign, bulk decisions, or automatic approval.
