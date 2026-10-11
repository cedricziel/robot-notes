import 'package:cupertino_ui/cupertino_ui.dart' as standalone_cupertino;
import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/material.dart' as legacy;
import 'package:material_ui/material_ui.dart' as material;

/// Projects standalone themes into Flutter themes for a Super Editor subtree.
///
/// Standalone controls retain their inherited theme. MediaQuery remains inherited,
/// including text scaling and reduced motion preferences.
class SuperEditorThemeBridge extends legacy.StatelessWidget {
  const SuperEditorThemeBridge({super.key, required this.child});

  final legacy.Widget child;

  @override
  legacy.Widget build(legacy.BuildContext context) {
    final source = material.Theme.of(context);
    final colors = source.colorScheme;
    final selection = source.textSelectionTheme;
    final apple = standalone_cupertino.CupertinoTheme.of(context);
    final appleText = apple.textTheme;
    return legacy.Theme(
      data: legacy.ThemeData(
        brightness: source.brightness,
        platform: source.platform,
        useMaterial3: source.useMaterial3,
        applyElevationOverlayColor: source.applyElevationOverlayColor,
        colorScheme: legacy.ColorScheme(
          brightness: colors.brightness,
          primary: colors.primary,
          onPrimary: colors.onPrimary,
          primaryContainer: colors.primaryContainer,
          onPrimaryContainer: colors.onPrimaryContainer,
          primaryFixed: colors.primaryFixed,
          primaryFixedDim: colors.primaryFixedDim,
          onPrimaryFixed: colors.onPrimaryFixed,
          onPrimaryFixedVariant: colors.onPrimaryFixedVariant,
          secondary: colors.secondary,
          onSecondary: colors.onSecondary,
          secondaryContainer: colors.secondaryContainer,
          onSecondaryContainer: colors.onSecondaryContainer,
          secondaryFixed: colors.secondaryFixed,
          secondaryFixedDim: colors.secondaryFixedDim,
          onSecondaryFixed: colors.onSecondaryFixed,
          onSecondaryFixedVariant: colors.onSecondaryFixedVariant,
          tertiary: colors.tertiary,
          onTertiary: colors.onTertiary,
          tertiaryContainer: colors.tertiaryContainer,
          onTertiaryContainer: colors.onTertiaryContainer,
          tertiaryFixed: colors.tertiaryFixed,
          tertiaryFixedDim: colors.tertiaryFixedDim,
          onTertiaryFixed: colors.onTertiaryFixed,
          onTertiaryFixedVariant: colors.onTertiaryFixedVariant,
          error: colors.error,
          onError: colors.onError,
          errorContainer: colors.errorContainer,
          onErrorContainer: colors.onErrorContainer,
          surface: colors.surface,
          onSurface: colors.onSurface,
          surfaceDim: colors.surfaceDim,
          surfaceBright: colors.surfaceBright,
          surfaceContainerLowest: colors.surfaceContainerLowest,
          surfaceContainerLow: colors.surfaceContainerLow,
          surfaceContainer: colors.surfaceContainer,
          surfaceContainerHigh: colors.surfaceContainerHigh,
          surfaceContainerHighest: colors.surfaceContainerHighest,
          onSurfaceVariant: colors.onSurfaceVariant,
          outline: colors.outline,
          outlineVariant: colors.outlineVariant,
          shadow: colors.shadow,
          scrim: colors.scrim,
          inverseSurface: colors.inverseSurface,
          onInverseSurface: colors.onInverseSurface,
          inversePrimary: colors.inversePrimary,
          surfaceTint: colors.surfaceTint,
        ),
        canvasColor: source.canvasColor,
        cardColor: source.cardColor,
        disabledColor: source.disabledColor,
        dividerColor: source.dividerColor,
        focusColor: source.focusColor,
        highlightColor: source.highlightColor,
        hintColor: source.hintColor,
        hoverColor: source.hoverColor,
        primaryColor: source.primaryColor,
        primaryColorDark: source.primaryColorDark,
        primaryColorLight: source.primaryColorLight,
        scaffoldBackgroundColor: source.scaffoldBackgroundColor,
        secondaryHeaderColor: source.secondaryHeaderColor,
        shadowColor: source.shadowColor,
        splashColor: source.splashColor,
        unselectedWidgetColor: source.unselectedWidgetColor,
        textTheme: _textTheme(source.textTheme),
        primaryTextTheme: _textTheme(source.primaryTextTheme),
        iconTheme: source.iconTheme,
        primaryIconTheme: source.primaryIconTheme,
        textSelectionTheme: legacy.TextSelectionThemeData(
          cursorColor: selection.cursorColor,
          selectionColor: selection.selectionColor,
          selectionHandleColor: selection.selectionHandleColor,
        ),
      ),
      child: cupertino.CupertinoTheme(
        data: cupertino.CupertinoThemeData(
          brightness: source.brightness,
          primaryColor: apple.primaryColor,
          primaryContrastingColor: apple.primaryContrastingColor,
          barBackgroundColor: apple.barBackgroundColor,
          scaffoldBackgroundColor: apple.scaffoldBackgroundColor,
          selectionHandleColor: apple.selectionHandleColor,
          applyThemeToAll: apple.applyThemeToAll,
          textTheme: cupertino.CupertinoTextThemeData(
            textStyle: appleText.textStyle,
            actionTextStyle: appleText.actionTextStyle,
            actionSmallTextStyle: appleText.actionSmallTextStyle,
            tabLabelTextStyle: appleText.tabLabelTextStyle,
            navTitleTextStyle: appleText.navTitleTextStyle,
            navLargeTitleTextStyle: appleText.navLargeTitleTextStyle,
            navActionTextStyle: appleText.navActionTextStyle,
            pickerTextStyle: appleText.pickerTextStyle,
            dateTimePickerTextStyle: appleText.dateTimePickerTextStyle,
          ),
        ),
        child: legacy.Material(
          type: legacy.MaterialType.transparency,
          child: child,
        ),
      ),
    );
  }
}

legacy.TextTheme _textTheme(material.TextTheme source) => legacy.TextTheme(
  displayLarge: source.displayLarge,
  displayMedium: source.displayMedium,
  displaySmall: source.displaySmall,
  headlineLarge: source.headlineLarge,
  headlineMedium: source.headlineMedium,
  headlineSmall: source.headlineSmall,
  titleLarge: source.titleLarge,
  titleMedium: source.titleMedium,
  titleSmall: source.titleSmall,
  bodyLarge: source.bodyLarge,
  bodyMedium: source.bodyMedium,
  bodySmall: source.bodySmall,
  labelLarge: source.labelLarge,
  labelMedium: source.labelMedium,
  labelSmall: source.labelSmall,
);
