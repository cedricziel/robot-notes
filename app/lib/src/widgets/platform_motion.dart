import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// Presents notes using mobile navigation or a stationary desktop fade.
Page<void> notesPage(
  BuildContext context, {
  required LocalKey key,
  required Widget child,
  required bool splitView,
}) {
  if (splitView || MediaQuery.disableAnimationsOf(context)) {
    return NoTransitionPage<void>(key: key, child: child);
  }
  switch (Theme.of(context).platform) {
    case TargetPlatform.iOS:
      return CupertinoPage<void>(key: key, child: child);
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
      return MaterialPage<void>(key: key, child: child);
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return CustomTransitionPage<void>(
        key: key,
        child: child,
        transitionDuration: const Duration(milliseconds: 120),
        reverseTransitionDuration: const Duration(milliseconds: 120),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      );
  }
}

/// Matches dialog motion to the platform and accessibility preference.
Future<T?> showPlatformDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? barrierLabel,
}) {
  if (MediaQuery.disableAnimationsOf(context)) {
    return showDialog<T>(
      context: context,
      builder: builder,
      barrierLabel: barrierLabel,
      animationStyle: AnimationStyle.noAnimation,
    );
  }
  switch (Theme.of(context).platform) {
    case TargetPlatform.iOS:
      return showCupertinoDialog<T>(
        context: context,
        builder: builder,
        barrierLabel: barrierLabel,
        barrierDismissible: true,
      );
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
      return showDialog<T>(
        context: context,
        builder: builder,
        barrierLabel: barrierLabel,
      );
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return showDialog<T>(
        context: context,
        builder: builder,
        barrierLabel: barrierLabel,
        animationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 120),
          reverseDuration: Duration(milliseconds: 120),
        ),
      );
  }
}

/// Desktop windows use dialogs even when resized below tablet width.
bool usesDesktopDialogs(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };

/// Uses native mobile sheets while honoring reduced-motion preferences.
Future<T?> showPlatformSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  if (Theme.of(context).platform == TargetPlatform.iOS) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final themes = InheritedTheme.capture(from: context, to: navigator.context);
    return navigator.push(
      _PlatformCupertinoSheetRoute<T>(
        reducedMotion: reducedMotion,
        builder: (context) =>
            themes.wrap(Material(child: Builder(builder: builder))),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: reducedMotion ? AnimationStyle.noAnimation : null,
    builder: builder,
  );
}

class _PlatformCupertinoSheetRoute<T> extends CupertinoSheetRoute<T> {
  _PlatformCupertinoSheetRoute({
    required this.reducedMotion,
    required WidgetBuilder builder,
  }) : super(
         scrollableBuilder: (context, controller) => builder(context),
         showDragHandle: true,
       );

  final bool reducedMotion;

  @override
  Duration get transitionDuration =>
      reducedMotion ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      reducedMotion ? Duration.zero : super.reverseTransitionDuration;
}
