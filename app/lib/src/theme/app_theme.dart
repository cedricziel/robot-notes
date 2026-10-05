import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';
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
  static const Color seed = Color(0xFF3659E3);

  static ThemeData light({TargetPlatform? platform}) =>
      _build(Brightness.light, platform ?? defaultTargetPlatform);

  static ThemeData dark({TargetPlatform? platform}) =>
      _build(Brightness.dark, platform ?? defaultTargetPlatform);

  static ThemeData _build(Brightness brightness, TargetPlatform platform) {
    final apple = isApplePlatform(platform);
    final dark = brightness == Brightness.dark;
    final canvas = dark ? const Color(0xFF17191F) : const Color(0xFFF5F6F9);
    final content = dark ? const Color(0xFF20232B) : Colors.white;
    final border = dark ? const Color(0xFF363B48) : const Color(0xFFE1E4EB);
    final ink = dark ? const Color(0xFFE8EBF2) : const Color(0xFF252A36);
    final muted = dark ? const Color(0xFFAAB2C3) : const Color(0xFF697386);
    final accent = dark ? const Color(0xFF9AAEFF) : seed;
    final selection = dark ? const Color(0xFF2B3659) : const Color(0xFFEBEFFF);
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness)
        .copyWith(
          primary: accent,
          onPrimary: dark ? const Color(0xFF15234F) : Colors.white,
          primaryContainer: selection,
          onPrimaryContainer: accent,
          secondary: accent,
          onSecondary: dark ? const Color(0xFF15234F) : Colors.white,
          secondaryContainer: selection,
          onSecondaryContainer: ink,
          surface: content,
          onSurface: ink,
          onSurfaceVariant: muted,
          surfaceContainerLowest: dark ? const Color(0xFF12141A) : Colors.white,
          surfaceContainerLow: canvas,
          surfaceContainer: dark
              ? const Color(0xFF262A34)
              : const Color(0xFFF0F2F7),
          surfaceContainerHigh: dark
              ? const Color(0xFF2C303B)
              : const Color(0xFFEBEEF4),
          surfaceContainerHighest: dark
              ? const Color(0xFF323744)
              : const Color(0xFFE5E9F1),
          outline: dark ? const Color(0xFF778195) : const Color(0xFF929BAA),
          outlineVariant: border,
          surfaceTint: Colors.transparent,
        );
    const controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
    );
    const panelShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
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
    final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      canvasColor: content,
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.6,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
        bodyLarge: text.bodyLarge?.copyWith(height: 1.5),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.4),
        labelLarge: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: controlShape,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: controlShape,
          elevation: 0,
          backgroundColor: content,
          foregroundColor: accent,
          surfaceTintColor: Colors.transparent,
          side: BorderSide(color: border),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: controlShape,
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: controlShape),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: controlShape),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: controlShape,
          side: BorderSide(color: border),
          selectedBackgroundColor: selection,
          selectedForegroundColor: accent,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: panelShape,
        backgroundColor: accent,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        highlightElevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: content,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        hintStyle: text.bodyMedium?.copyWith(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent, width: 2),
        ),
      ),
      cardTheme: CardThemeData(
        color: content,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: panelShape.copyWith(side: BorderSide(color: border)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: content,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: panelShape.copyWith(side: BorderSide(color: border)),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(content),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: const WidgetStatePropertyAll(panelShape),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
          elevation: const WidgetStatePropertyAll(3),
        ),
      ),
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
        selectedTileColor: selection,
        selectedColor: accent,
        iconColor: muted,
        shape: controlShape,
      ),
      chipTheme: ChipThemeData(
        labelStyle: text.labelMedium,
        backgroundColor: content,
        selectedColor: selection,
        surfaceTintColor: Colors.transparent,
        shape: controlShape,
        side: BorderSide(color: border),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: content,
        surfaceTintColor: Colors.transparent,
        shape: panelShape,
      ),
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
    return MarkdownStyleSheet(
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: const TextStyle(fontWeight: FontWeight.bold),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
      blockquote: body,
      img: body,
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
      checkbox: text.bodyMedium?.copyWith(color: scheme.primary),
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
