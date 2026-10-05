import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// A fixed-width side panel with a drag handle on its trailing edge, so the
/// user can widen a folder tree that has deep paths or narrow one that is
/// eating into the list. Width is owned by the parent ([width] +
/// [onWidthChanged]) so the shell and the notes list can persist it
/// however they like; the panel only clamps and reports.
class ResizablePanel extends StatefulWidget {
  const ResizablePanel({
    required this.width,
    required this.onWidthChanged,
    required this.child,
    this.minWidth = 200,
    this.maxWidth = 420,
    super.key,
  });

  final double width;
  final ValueChanged<double> onWidthChanged;
  final double minWidth;
  final double maxWidth;
  final Widget child;

  /// Hit-target width of the drag handle (the painted divider is 1px).
  static const double handleWidth = 8;

  @override
  State<ResizablePanel> createState() => _ResizablePanelState();
}

class _ResizablePanelState extends State<ResizablePanel> {
  bool _dragging = false;
  bool _hovering = false;
  bool _focused = false;

  void _resize(double delta) {
    final width = (widget.width + delta).clamp(
      widget.minWidth,
      widget.maxWidth,
    );
    if (width != widget.width) widget.onWidthChanged(width);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlight = _dragging || _hovering || _focused;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: widget.width.clamp(widget.minWidth, widget.maxWidth),
          child: widget.child,
        ),
        MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Semantics(
            label: 'Sidebar width',
            value: '${widget.width.round()}',
            increasedValue:
                '${(widget.width + 20).clamp(widget.minWidth, widget.maxWidth).round()}',
            decreasedValue:
                '${(widget.width - 20).clamp(widget.minWidth, widget.maxWidth).round()}',
            onIncrease: () => _resize(20),
            onDecrease: () => _resize(-20),
            child: Focus(
              onFocusChange: (focused) => setState(() => _focused = focused),
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent || event is KeyRepeatEvent) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _resize(-20);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    _resize(20);
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: GestureDetector(
                key: const Key('panel.resizeHandle'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => setState(() => _dragging = true),
                onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                onHorizontalDragCancel: () => setState(() => _dragging = false),
                onHorizontalDragUpdate: (details) {
                  final next = (widget.width + details.delta.dx).clamp(
                    widget.minWidth,
                    widget.maxWidth,
                  );
                  if (next != widget.width) widget.onWidthChanged(next);
                },
                child: SizedBox(
                  width: ResizablePanel.handleWidth,
                  child: Center(
                    child: AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 120),
                      width: highlight ? 3 : 1,
                      color: highlight ? scheme.primary : scheme.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
