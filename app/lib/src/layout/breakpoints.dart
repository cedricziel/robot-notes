import 'package:flutter/widgets.dart';

/// Material 3 window size classes, collapsed to the four the app actually
/// distinguishes. Every width-dependent layout decision in the client goes
/// through [Breakpoints] so screens agree on where "narrow" ends.
///
/// - [compact]: phones in portrait. Bottom nav, FAB menu, folder drawer,
///   stacked editor/preview, search as a top sheet.
/// - [medium]: large phones in landscape, small tablets, narrow desktop
///   windows. Toolbar actions, inline folder sidebar, side-by-side
///   editor/preview, search as a centered palette.
/// - [expanded]: tablets and typical desktop windows. Same chrome as
///   [medium]; a wider reading column.
/// - [large]: wide desktop windows. Three-pane shell (folders | notes |
///   note) instead of pushing a note over the list.
enum WindowSizeClass {
  compact,
  medium,
  expanded,
  large;

  /// Whether the window is at least [other] wide.
  bool operator >=(WindowSizeClass other) => index >= other.index;

  /// Whether the window is narrower than [other].
  bool operator <(WindowSizeClass other) => index < other.index;
}

abstract final class Breakpoints {
  /// Lower bound (inclusive) of [WindowSizeClass.medium].
  static const double medium = 600;

  /// Lower bound (inclusive) of [WindowSizeClass.expanded].
  static const double expanded = 840;

  /// Lower bound (inclusive) of [WindowSizeClass.large]. Chosen so the
  /// three-pane shell always leaves the note pane at least as wide as the
  /// reading column: 240 (folders) + 360 (list) + 600 (note).
  static const double large = 1200;

  static WindowSizeClass classify(double width) {
    if (width >= large) return WindowSizeClass.large;
    if (width >= expanded) return WindowSizeClass.expanded;
    if (width >= medium) return WindowSizeClass.medium;
    return WindowSizeClass.compact;
  }

  /// Size class for the whole window, from [MediaQuery].
  static WindowSizeClass of(BuildContext context) =>
      classify(MediaQuery.sizeOf(context).width);

  /// Size class for a widget's own constraints (a pane inside the shell
  /// is narrower than the window it lives in).
  static WindowSizeClass fromConstraints(BoxConstraints constraints) =>
      classify(constraints.maxWidth);
}

/// Shared pane sizes for the wide layouts, so the folder sidebar is the
/// same width whether the notes list or the three-pane shell renders it.
abstract final class PaneSizes {
  static const double sidebarDefault = 260;
  static const double sidebarMin = 200;
  static const double sidebarMax = 420;

  /// Width of the notes-list pane in the three-pane shell.
  static const double listPane = 380;

  /// Comfortable line length for reading and writing prose.
  static const double readingColumn = 760;

  /// Editor + preview side by side, each near a reading column.
  static const double editorSplit = 1400;
}
