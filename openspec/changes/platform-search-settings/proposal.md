# Platform-aware search and settings presentation

## Why
Compact search uses custom top-sheet motion, iOS uses a Material sheet, and search/settings dialogs do not consistently honor reduced motion.

## What Changes
- Use Cupertino sheets on compact iOS and Material bottom sheets on compact Android.
- Keep desktop search and settings in dialogs at every window width.
- Apply platform dialog motion and reduced-motion support to search, settings, and disconnect confirmation.

## Impact
Presentation changes only. Search, account state, disconnect confirmation, and app-lock behavior retain their existing contracts.
