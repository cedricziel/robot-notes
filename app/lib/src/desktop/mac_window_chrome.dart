import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import 'window_chrome.dart';

/// Height, in logical pixels, of the macOS unified title bar's content
/// inset and drag strip. Matches the traffic-light row's height closely
/// enough that nothing the app draws sits under the buttons.
const double kMacTitleBarInset = 28;

/// Makes room for, and drives, the macOS unified (transparent) title bar.
///
/// On macOS only (native window chrome is set to the hidden title-bar
/// style by [WindowChromeController] at startup — see
/// `window_chrome_io.dart`) this:
///
///  * raises the ambient [MediaQuery] top padding to at least
///    [kMacTitleBarInset], so [child] can lay out below the traffic
///    lights the same way it already does below a phone's status bar;
///  * draws a transparent strip across the top of that height that drags
///    the window on pan and zooms it on double-tap/double-click, standing
///    in for the title bar's own drag/zoom behaviour that the app's own
///    content now covers.
///
/// Everywhere else this returns [child] unchanged.
class MacWindowChrome extends StatelessWidget {
  const MacWindowChrome({
    required this.child,
    this.onDragStart,
    this.onDoubleTap,
    super.key,
  });

  final Widget child;

  /// Called when the drag strip's pan gesture starts. Defaults to
  /// [startWindowDrag]; tests override this to avoid touching the real
  /// window-manager platform channel.
  final ValueChanged<DragStartDetails>? onDragStart;

  /// Called on a double-tap of the drag strip. Defaults to
  /// [toggleWindowZoom]; tests override this for the same reason.
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return child;

    final media = MediaQuery.of(context);
    final currentTop = media.padding.top;
    final insetTop = currentTop < kMacTitleBarInset
        ? kMacTitleBarInset
        : currentTop;

    return MediaQuery(
      data: media.copyWith(padding: media.padding.copyWith(top: insetTop)),
      child: Stack(
        children: [
          child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: kMacTitleBarInset,
            child: GestureDetector(
              key: const Key('window.dragStrip'),
              behavior: HitTestBehavior.translucent,
              onPanStart: onDragStart ?? _startDrag,
              onDoubleTap: onDoubleTap ?? _toggleZoom,
            ),
          ),
        ],
      ),
    );
  }
}

void _startDrag(DragStartDetails details) {
  unawaited(startWindowDrag());
}

void _toggleZoom() {
  unawaited(toggleWindowZoom());
}
