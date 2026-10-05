# Design

Use standalone package imports throughout application-owned widgets and tests, retaining core Flutter foundation/widgets/services imports. Native integrations continue using existing target checks. Both UI packages are cross-platform dependencies; platform choice remains a presentation decision.

MaterialApp.router owns the standalone theme. A temporary official MaterialUiCompatibilityBridge supplies legacy ThemeData and localizations below its builder. Its deprecation suppression is local and documented for removal when remaining dependencies migrate. MarkdownStyleSheet is constructed explicitly to avoid incompatible legacy ThemeData arguments. A legacy import in the compatibility regression test is deliberate.

The client requires Dart ^3.13.0 and Flutter >=3.47.0; the server-only SDK requirement remains unchanged. CI pins Flutter 3.47.2.
