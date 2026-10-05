---
name: verify-project-local
description: Verify Robot Notes changes with a throwaway local server and the real Flutter app connected to it. Use when the user says verify locally or requests local end-to-end validation; maintain this workflow as project tooling changes.
---

# Verify project locally

“Verify locally” means a running disposable development instance and the actual app connected to it. Tests, screenshots from mocked widgets, and successful builds are supporting checks; they do not satisfy this request alone.

## Stand up the instance

Run from the repository root. Resolve workspace dependencies and build the current web client with `cd app && flutter build web --no-pub` if it is stale. Start `scripts/start.sh` in a terminal/PTY (`tty: true` with exec_command); Dart Frog's dev listener fails without a terminal. The script chooses a free loopback port, creates an isolated temporary data directory and disposable API key, serves `app/build/web`, and prints the URL/key. It removes its scratch directory on exit. Keep the process handle for cleanup.

Open that URL in a fresh agent-owned browser tab. Use the real setup flow and printed key/display name to connect. HTTP is permitted only for exact loopback hosts; remote URLs still require HTTPS. Do not use a production server or existing user notes/configuration. Native apps can also connect to this instance; use a simulator or isolated test app profile rather than replacing the user's saved desktop connection.

Seed a small note/folder through the local API if helpful (`POST /notes` with bearer key, JSON title/path/content, X-Actor). Then perform a real app write: open or create a note, edit and save it, reload/reopen, and confirm the persisted content through the server API. Exercise affected navigation, search, settings, or other controls. Confirm live connectivity rather than merely rendering the landing screen.

## Responsive and platform checks

For layout changes, resize the same browser session through phone portrait/landscape, tablet portrait/landscape, and desktop widths. Check overflow, navigation, reading/editing, and state retention. Representative logical sizes: 390×844, 844×390, 768×1024, 1024×768, 1440×900. Reset temporary viewport overrides afterward.

Use available native toolchains when relevant. macOS can build iOS simulators and macOS; Android requires its SDK; native Linux/Windows require their own hosts/toolchains. Never describe browser dimensions or TargetPlatform widget tests as native OS/device validation. If a requested target cannot run here, state the exact missing toolchain.

## Evidence and cleanup

Capture a screenshot of the real connected app and check browser/server errors. Record the real interaction performed, persisted result, viewport/platform coverage, build/test results, and limitations. Keep disposable credentials, runtime data and transient logs out of Git. Stop only processes started for this verification, close verification tabs, reset viewport overrides, and remove disposable data (start.sh does this on exit). Leave the environment running only if the user asks for it.

Maintain this skill and its helper when actual use reveals a project-specific improvement. Keep changes narrow and validate the helper by starting it, checking /healthz, and stopping it. PR creation/publication is a separate user-authorized action.
