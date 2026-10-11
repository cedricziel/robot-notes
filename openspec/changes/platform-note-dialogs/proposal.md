# Platform-aware note and folder dialogs

## Why
Folder creation, note movement, and note deletion use adaptive controls but still present Material dialog routes on every platform.

## What Changes
Use the shared platform dialog policy for folder creation, note movement, and deletion from either the reader or list. Retain existing confirmation and error handling.

## Impact
Presentation only: Cupertino motion on iOS, Material motion on Android, short desktop fades, and no animation with reduced motion.
