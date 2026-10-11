import 'package:adaptive_super_editor/src/theme_bridge.dart';
import 'package:cupertino_ui/cupertino_ui.dart' as standalone_cupertino;
import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material;

void main() {
  testWidgets('projects dark iOS themes without changing standalone themes', (
    tester,
  ) async {
    final source = material.ThemeData(
      brightness: legacy.Brightness.dark,
      platform: legacy.TargetPlatform.iOS,
      colorScheme: material.ColorScheme.fromSeed(
        seedColor: const legacy.Color(0xff9a60d0),
        brightness: legacy.Brightness.dark,
      ),
      textTheme: const material.TextTheme(
        bodyLarge: legacy.TextStyle(fontFamily: 'EditorFont', fontSize: 23),
      ),
      textSelectionTheme: const material.TextSelectionThemeData(
        cursorColor: legacy.Color(0xffdd1122),
        selectionColor: legacy.Color(0xffaabbcc),
        selectionHandleColor: legacy.Color(0xff22aa44),
      ),
    );
    late material.ThemeData outside;
    late material.ThemeData inside;
    late legacy.ThemeData editor;
    late cupertino.CupertinoThemeData editorCupertino;
    late standalone_cupertino.CupertinoThemeData sourceCupertino;
    late legacy.MediaQueryData inheritedMedia;
    const media = legacy.MediaQueryData(
      textScaler: legacy.TextScaler.linear(1.8),
      disableAnimations: true,
    );

    await tester.pumpWidget(
      legacy.MediaQuery(
        data: media,
        child: legacy.Directionality(
          textDirection: legacy.TextDirection.ltr,
          child: material.Theme(
            data: source,
            child: legacy.Builder(
              builder: (context) {
                outside = material.Theme.of(context);
                sourceCupertino = standalone_cupertino.CupertinoTheme.of(
                  context,
                );
                return SuperEditorThemeBridge(
                  child: legacy.Builder(
                    builder: (context) {
                      inside = material.Theme.of(context);
                      editor = legacy.Theme.of(context);
                      editorCupertino = cupertino.CupertinoTheme.of(context);
                      inheritedMedia = legacy.MediaQuery.of(context);
                      return const legacy.SizedBox();
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(editor.brightness, legacy.Brightness.dark);
    expect(editor.platform, legacy.TargetPlatform.iOS);
    expect(editor.colorScheme.primary, outside.colorScheme.primary);
    expect(
      editor.colorScheme.surfaceContainerHighest,
      outside.colorScheme.surfaceContainerHighest,
    );
    expect(editor.colorScheme.onSurface, outside.colorScheme.onSurface);
    expect(editor.textTheme.bodyLarge, outside.textTheme.bodyLarge);
    expect(
      editor.textSelectionTheme.cursorColor,
      outside.textSelectionTheme.cursorColor,
    );
    expect(
      editor.textSelectionTheme.selectionColor,
      outside.textSelectionTheme.selectionColor,
    );
    expect(
      editor.textSelectionTheme.selectionHandleColor,
      outside.textSelectionTheme.selectionHandleColor,
    );
    expect(editorCupertino.brightness, legacy.Brightness.dark);
    expect(editorCupertino.primaryColor, sourceCupertino.primaryColor);
    expect(
      editorCupertino.scaffoldBackgroundColor,
      sourceCupertino.scaffoldBackgroundColor,
    );
    expect(
      editorCupertino.textTheme.textStyle,
      sourceCupertino.textTheme.textStyle,
    );
    expect(inside, outside);
    expect(inheritedMedia, same(media));
  });

  testWidgets('updates editor brightness, platform, and colors with the host', (
    tester,
  ) async {
    final theme = legacy.ValueNotifier(
      material.ThemeData(
        brightness: legacy.Brightness.light,
        platform: legacy.TargetPlatform.android,
        colorScheme: material.ColorScheme.fromSeed(
          seedColor: const legacy.Color(0xffaa4400),
        ),
      ),
    );
    addTearDown(theme.dispose);
    late legacy.ThemeData editor;
    late cupertino.CupertinoThemeData apple;
    final child = SuperEditorThemeBridge(
      child: legacy.Builder(
        builder: (context) {
          editor = legacy.Theme.of(context);
          apple = cupertino.CupertinoTheme.of(context);
          return const legacy.SizedBox();
        },
      ),
    );
    await tester.pumpWidget(
      legacy.Directionality(
        textDirection: legacy.TextDirection.ltr,
        child: legacy.ValueListenableBuilder<material.ThemeData>(
          valueListenable: theme,
          child: child,
          builder: (context, data, child) =>
              material.Theme(data: data, child: child!),
        ),
      ),
    );
    expect(editor.brightness, legacy.Brightness.light);
    expect(editor.platform, legacy.TargetPlatform.android);
    expect(editor.colorScheme.primary, theme.value.colorScheme.primary);

    theme.value = material.ThemeData(
      brightness: legacy.Brightness.dark,
      platform: legacy.TargetPlatform.macOS,
      colorScheme: material.ColorScheme.fromSeed(
        seedColor: const legacy.Color(0xff007799),
        brightness: legacy.Brightness.dark,
      ),
    );
    await tester.pump();

    expect(editor.brightness, legacy.Brightness.dark);
    expect(editor.platform, legacy.TargetPlatform.macOS);
    expect(editor.colorScheme.primary, theme.value.colorScheme.primary);
    expect(editor.colorScheme.surface, theme.value.colorScheme.surface);
    expect(apple.brightness, legacy.Brightness.dark);
  });
}
