---
name: verify-project-local
description: Verify Robot Notes changes with a throwaway local server and the real Flutter app connected to it. Use when the user says verify locally or requests local end-to-end validation; maintain this workflow as project tooling changes.
---

# Verify project locally

“Verify locally” means a running disposable development instance and the actual app connected to it. Tests, screenshots from mocked widgets, and successful builds are supporting checks; they do not satisfy this request alone.

## Stand up the instance

Run from the repository root. Resolve workspace dependencies and build the current web client with `cd app && flutter build web --no-pub` if it is stale. This checkout has no `scripts/start.sh`; start the server directly. Choose two free loopback ports, one for HTTP and one for the Dart VM service, and create a temporary data directory and disposable API key. From `server`, run `dart_frog dev --hostname 127.0.0.1 --port <http-port> --dart-vm-service-port <vm-port>` in a terminal/PTY (`tty: true` with exec_command). Do not use the default VM-service port 8181, which may belong to another running app.

Use a clean child environment with only the required runtime variables such as `PATH`, `HOME`, and `TERM`, plus explicit `ROBOT_NOTES_API_KEY`, `ROBOT_NOTES_DATA_DIR`, `ROBOT_NOTES_PORT`, `ROBOT_NOTES_PUBLIC_URL`, and an absolute `ROBOT_NOTES_WEB_DIR` pointing to `app/build/web`. Do not inherit production authentication, embedding, or telemetry settings. Keep the process handle and temporary directory path for cleanup. Confirm `/healthz` succeeds before opening the app; a dev-server startup banner alone does not prove the service is listening.

Open that URL in a fresh agent-owned browser tab. Use the real setup flow with the disposable key and a test display name to connect. HTTP is permitted only for exact loopback hosts; remote URLs still require HTTPS. Do not use a production server or existing user notes/configuration. Native apps can also connect to this instance; use a simulator or isolated test app profile rather than replacing the user's saved desktop connection.

Seed a small note/folder through the local API if helpful (`POST /notes` with bearer key, JSON title/path/content, X-Actor). Then perform a real app write: open or create a note, edit and save it, reload/reopen, and confirm the persisted content through the server API. Exercise affected navigation, search, settings, or other controls. Confirm live connectivity rather than merely rendering the landing screen.

## Responsive and platform checks

For layout changes, resize the same browser session through phone portrait/landscape, tablet portrait/landscape, and desktop widths. Check overflow, navigation, reading/editing, and state retention. Representative logical sizes: 390×844, 844×390, 768×1024, 1024×768, 1440×900. Reset temporary viewport overrides afterward.

Use available native toolchains when relevant. macOS can build iOS simulators and macOS; Android requires its SDK; native Linux/Windows require their own hosts/toolchains. Never describe browser dimensions or TargetPlatform widget tests as native OS/device validation. If a requested target cannot run here, state the exact missing toolchain.

## Evidence and cleanup

Capture a screenshot of the real connected app and check browser/server errors. Record the real interaction performed, persisted result, viewport/platform coverage, build/test results, and limitations. Keep disposable credentials, runtime data and transient logs out of Git. Stop only processes started for this verification, close verification tabs, reset viewport overrides, and remove disposable data. Leave the environment running only if the user asks for it.

Maintain this skill and any startup helper when actual use reveals a project-specific improvement. Keep changes narrow and validate the helper by starting it, checking /healthz, and stopping it. PR creation/publication is a separate user-authorized action.

## Standby and authentication checks

Use lifecycle tests for repeated pause/resume, stalled refresh requests, transient network failures after wake-up, and preservation of the mounted workspace. A successful web edit with a static API key does not verify OAuth renewal or native laptop sleep. Report those coverage limits explicitly. Refresh requests must have a bounded timeout so a request interrupted by sleep cannot block every later renewal.
