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

/// Matches vault dialog motion to the platform and accessibility preference.
Future<T?> showVaultDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  if (MediaQuery.disableAnimationsOf(context)) {
    return showDialog<T>(
      context: context,
      builder: builder,
      animationStyle: AnimationStyle.noAnimation,
    );
  }
  switch (Theme.of(context).platform) {
    case TargetPlatform.iOS:
      return showCupertinoDialog<T>(
        context: context,
        builder: builder,
        barrierDismissible: true,
      );
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
      return showDialog<T>(context: context, builder: builder);
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return showDialog<T>(
        context: context,
        builder: builder,
        animationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 120),
          reverseDuration: Duration(milliseconds: 120),
        ),
      );
  }
}
