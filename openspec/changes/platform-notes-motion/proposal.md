# Platform motion for notes and vault dialogs

## Why
Notes navigation and vault dialogs need motion appropriate to their host platform and reduced-motion settings.

## What Changes
- Use Cupertino navigation on iOS and Material navigation on Android.
- Use brief fades for compact desktop navigation and vault dialogs.
- Keep split-view note selection stationary.
- Disable route and dialog animations when reduced motion is requested.

## Impact
Changes are limited to notes navigation and vault management dialogs. Vault operations and note persistence remain unchanged.
