import 'dart:math' show min;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

/// Captures the page messenger before an async action or route closure.
class PlatformFeedback {
  PlatformFeedback.of(BuildContext context)
    : _messenger = ScaffoldMessenger.of(context),
      _platform = Theme.of(context).platform,
      _colors = Theme.of(context).colorScheme,
      _width = MediaQuery.sizeOf(context).width,
      _reducedMotion = MediaQuery.disableAnimationsOf(context);

  final ScaffoldMessengerState _messenger;
  final TargetPlatform _platform;
  final ColorScheme _colors;
  final double _width;
  final bool _reducedMotion;

  void show(String message, {bool error = false}) {
    if (!_messenger.mounted) return;
    final desktop = switch (_platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };
    final ios = _platform == TargetPlatform.iOS;
    final adapted = desktop || ios;
    final foreground = error ? _colors.onErrorContainer : _colors.onSurface;
    _messenger.clearSnackBars();
    _messenger.removeCurrentSnackBar();
    _messenger.showSnackBar(
      SnackBar(
        behavior: ios ? SnackBarBehavior.fixed : SnackBarBehavior.floating,
        width: desktop
            ? min(420, (_width - 24).clamp(0, double.infinity))
            : null,
        backgroundColor: adapted
            ? (error ? _colors.errorContainer : _colors.surfaceContainerHigh)
            : null,
        elevation: adapted ? (desktop ? 3 : 0) : null,
        shape: adapted
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(desktop ? 8 : 0),
                side: BorderSide(color: _colors.outlineVariant),
              )
            : null,
        padding: adapted
            ? const EdgeInsets.only(left: 12, top: 4, bottom: 4)
            : null,
        showCloseIcon: adapted,
        closeIconColor: adapted ? foreground : null,
        duration: Duration(seconds: error ? 8 : 4),
        content: Semantics(
          container: true,
          liveRegion: true,
          child: adapted
              ? Row(
                  children: [
                    Icon(
                      ios || _platform == TargetPlatform.macOS
                          ? (error
                                ? CupertinoIcons.exclamationmark_triangle
                                : CupertinoIcons.check_mark_circled)
                          : (error
                                ? Icons.error_outline
                                : Icons.check_circle_outline),
                      size: 18,
                      color: foreground,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        message,
                        style: TextStyle(
                          color: foreground,
                          fontSize: ios ? 14 : 13,
                        ),
                      ),
                    ),
                  ],
                )
              : Text(message),
        ),
      ),
      snackBarAnimationStyle: _reducedMotion
          ? AnimationStyle.noAnimation
          : adapted
          ? AnimationStyle(
              duration: Duration(milliseconds: desktop ? 120 : 180),
              reverseDuration: Duration(milliseconds: desktop ? 100 : 150),
            )
          : null,
    );
  }
}
