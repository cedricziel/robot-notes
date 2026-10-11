## Why

The workspace combines a full-width underlined vault picker with a second toolbar. Both the picker and routed content can reserve the system top inset, producing unnecessary blank space. Vault dialogs also ignore the existing Apple control adaptation.

## What changes

Use a compact vault menu, keep management actions beside it, and consume the top inset once at the session boundary. Adapt vault dialogs to the host platform. Place session controls below the route navigator so menus and dialogs have an overlay, while keeping the app lock above all routes. Return vault switches to `/`.

## Non-goals

This first slice does not replace the editor, change server behavior, or introduce another UI library.

## Impact

Flutter session layout and vault controls on all supported platforms.
