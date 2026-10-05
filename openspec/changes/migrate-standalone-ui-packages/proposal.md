# Standalone Flutter UI packages

## Why

Move the redesigned client to the official material_ui and cupertino_ui packages while preserving Android, iOS, macOS, Windows, Linux, and web support. The existing go_router dependency already uses standalone Material types.

## Changes

Declare material_ui ^1.5.0 and cupertino_ui ^1.1.1 directly. Raise the client minimum to Flutter 3.47.0 / Dart 3.13.0. Migrate application and test imports. Retain adaptive platform behavior and the shared visual theme.

Provide a temporary root MaterialUiCompatibilityBridge for unmigrated dependencies, including flutter_markdown_plus. Build Markdown styles explicitly from the standalone theme, with platform and light/dark regression coverage. Align documentation and the Docker web builder with the required SDK.

## Non-goals

No platform is removed. No app architecture rewrite, server SDK minimum change, or unrelated dependency upgrades. Native platform release certification remains a separate build-matrix responsibility.
