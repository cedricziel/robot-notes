## Tasks

- [x] Reproduce Apple vault dialog mismatch with widget tests.
- [x] Compact the vault selector and consume the workspace inset once.
- [x] Adapt vault dialogs while preserving management behavior.
- [x] Put session controls below the navigator and cover dialog opening with a router test.
- [x] Verify widget tests, analysis, and the running local app.

## Definition of Done

Vault switching, creation, and renaming pass their widget tests. Inspect the connected workspace at desktop and phone sizes and record runtime limitations.

## Verification

The full client suite passed 828 tests before the navigator correction. The correction passed 68 focused startup, vault, and router tests. The final app-lock placement passed 11 startup and lock tests. A separate regression test reproduced the missing-session frame during redirect and passed with the loading guard.

The release web build passed. Changed-file analysis and strict OpenSpec validation passed. A disposable server confirmed note editing, saving, and reload, with the persisted content checked through the API. The connected app was inspected at 390×844, 844×390, 768×1024, 1024×768, and 1440×900. Live vault creation and selection returned to the notes home route.

These are browser viewport checks and Flutter platform widget tests. Native platform builds and installed-app replacement were not performed. The existing server warns about a route conflict between the two notes/files routes; file upload was outside this check.

The final release build also passed a live disconnect/reconnect cycle with no browser warnings or errors. Disposable browser credentials were cleared and the preview server was stopped. The restored `scripts/start.sh` passed a health check and removed its temporary data on shutdown.
