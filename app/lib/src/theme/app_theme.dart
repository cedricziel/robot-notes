import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Whether [platform] is one of Apple's, where the app should feel like a
/// Cupertino citizen (no ink ripples, iOS-style dialogs, Menlo for code)
/// rather than an Android one. The theme and the adaptive widgets both key
/// off this so they agree on where "Apple" begins.
bool isApplePlatform(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

/// The one place the app's [ThemeData] is assembled. Both brightnesses
/// derive from the same seed; everything else here is density and
/// component tuning that used to be implicit (or absent).
abstract final class AppTheme {
  static const Color seed = Colors.indigo;

  static ThemeData light({TargetPlatform? platform}) =>
      _build(Brightness.light, platform ?? defaultTargetPlatform);

  static ThemeData dark({TargetPlatform? platform}) =>
      _build(Brightness.dark, platform ?? defaultTargetPlatform);

  static ThemeData _build(Brightness brightness, TargetPlatform platform) {
    final apple = isApplePlatform(platform);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      platform: platform,
      // Tighter controls on desktop, standard touch targets on mobile.
      visualDensity: VisualDensity.adaptivePlatformDensity,
      // Ink ripples are a Material signature that reads as "Android" on an
      // iPhone or a Mac; Apple platforms get a plain highlight instead.
      // (Typography already follows the platform: ThemeData picks the
      // system font — San Francisco on iOS/macOS — for `platform`.)
      splashFactory: apple ? NoSplash.splashFactory : null,
    );
    return base.copyWith(
      // Flat app bars sit better next to the inline sidebar and the
      // three-pane shell than a tinted, elevated one.
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        // iOS centers navigation-bar titles; macOS (like the desktop
        // three-pane shell it usually runs in) and everything else keep
        // them leading-aligned.
        centerTitle: platform == TargetPlatform.iOS,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      listTileTheme: ListTileThemeData(
        selectedTileColor: scheme.secondaryContainer,
        selectedColor: scheme.onSecondaryContainer,
      ),
      chipTheme: ChipThemeData(
        labelStyle: base.textTheme.labelMedium,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: const DialogThemeData(surfaceTintColor: Colors.transparent),
    );
  }

  /// Monospace stack for code in notes. Apple ships Menlo on every iPhone
  /// and Mac but has no generic `monospace` alias, so it goes first there;
  /// elsewhere the generic family resolves to the platform's own choice.
  static TextStyle codeFont(TargetPlatform platform) =>
      isApplePlatform(platform)
      ? const TextStyle(
          fontFamily: 'Menlo',
          fontFamilyFallback: ['monospace', 'Courier New'],
        )
      : const TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: ['Menlo', 'Consolas', 'Courier New'],
        );

  /// Markdown styling for both the read-only note body and the editor's
  /// live preview, so they render identically. Derived from the ambient
  /// theme rather than the package defaults: readable line height,
  /// scheme-tinted code and quote surfaces, and no serif surprises.
  static MarkdownStyleSheet markdown(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final body = text.bodyLarge?.copyWith(height: 1.5);
    final code = codeFont(theme.platform).copyWith(
      fontSize: (text.bodyMedium?.fontSize ?? 14) * 0.95,
      height: 1.45,
      color: scheme.onSurface,
    );
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      pPadding: const EdgeInsets.only(bottom: 8),
      h1: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
      h2: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      h3: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      h4: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      h5: text.titleSmall,
      h6: text.labelLarge,
      h1Padding: const EdgeInsets.only(top: 16, bottom: 4),
      h2Padding: const EdgeInsets.only(top: 16, bottom: 4),
      h3Padding: const EdgeInsets.only(top: 12, bottom: 4),
      listBullet: body,
      code: code,
      codeblockDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      tableBorder: TableBorder.all(color: scheme.outlineVariant),
      tableHead: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      tableBody: body,
      a: TextStyle(
        color: scheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: scheme.primary,
      ),
    );
  }
}
