import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

/// Whether widgets under [context] should take their Cupertino form. Keyed
/// off the theme's platform (not `defaultTargetPlatform` directly) so a
/// test or a host can pin it, exactly as Flutter's own `.adaptive`
/// constructors do.
bool useCupertino(BuildContext context) =>
    isApplePlatform(Theme.of(context).platform);

/// The platform's back glyph: a chevron on iOS/macOS, an arrow elsewhere.
/// Keyed off the theme like everything else here, whereas
/// [Icons.adaptive] reads `defaultTargetPlatform` directly.
IconData adaptiveBackIcon(BuildContext context) =>
    useCupertino(context) ? Icons.arrow_back_ios : Icons.arrow_back;

/// The platform's "more" glyph: horizontal dots on iOS/macOS, vertical
/// elsewhere.
IconData adaptiveMoreIcon(BuildContext context) =>
    useCupertino(context) ? Icons.more_horiz : Icons.more_vert;

/// A dialog button for an [AlertDialog.adaptive]: a [CupertinoDialogAction]
/// on iOS and macOS, a Material button elsewhere. [primary] marks the
/// action the dialog exists for (Delete, Move, Create); on Material it is a
/// [FilledButton] to keep the existing emphasis, on Cupertino it is the
/// default action, and [destructive] additionally paints it red there.
Widget adaptiveDialogAction(
  BuildContext context, {
  required VoidCallback? onPressed,
  required Widget child,
  Key? key,
  bool primary = false,
  bool destructive = false,
}) {
  if (useCupertino(context)) {
    return CupertinoDialogAction(
      key: key,
      onPressed: onPressed,
      isDefaultAction: primary,
      isDestructiveAction: destructive,
      child: child,
    );
  }
  if (primary) {
    return FilledButton(key: key, onPressed: onPressed, child: child);
  }
  return TextButton(key: key, onPressed: onPressed, child: child);
}

/// A single-line text input for inside an [AlertDialog.adaptive]: a
/// [CupertinoTextField] (with its placeholder) on iOS and macOS, a Material
/// [TextFormField] with a label elsewhere. Both report edits through
/// [onChanged] and start from [initialValue]; the widget owns its
/// controller either way, so callers keep no state beyond the draft.
class AdaptiveDialogTextField extends StatefulWidget {
  const AdaptiveDialogTextField({
    required this.label,
    required this.hint,
    required this.onChanged,
    this.initialValue = '',
    this.enabled = true,
    this.autofocus = true,
    super.key,
  });

  final String label;
  final String hint;
  final ValueChanged<String> onChanged;
  final String initialValue;
  final bool enabled;
  final bool autofocus;

  @override
  State<AdaptiveDialogTextField> createState() =>
      _AdaptiveDialogTextFieldState();
}

class _AdaptiveDialogTextFieldState extends State<AdaptiveDialogTextField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (useCupertino(context)) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: CupertinoTextField(
          controller: _controller,
          placeholder: widget.hint.isEmpty ? widget.label : widget.hint,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          onChanged: widget.onChanged,
        ),
      );
    }
    return TextFormField(
      controller: _controller,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
      ),
    );
  }
}

/// An action or selected choice in an [AdaptiveMenu].
class AdaptiveMenuEntry {
  const AdaptiveMenuEntry({
    required this.label,
    required this.onSelected,
    this.key,
    this.destructive = false,
    this.selected,
  });

  final String label;
  final VoidCallback onSelected;
  final Key? key;
  final bool destructive;
  final bool? selected;
}

/// Opens an iOS action sheet, a desktop anchored menu, or a Material popup.
class AdaptiveMenu extends StatefulWidget {
  const AdaptiveMenu({
    required this.entries,
    this.tooltip,
    this.child,
    this.enabled = true,
    this.compact = false,
    super.key,
  });

  final List<AdaptiveMenuEntry> entries;
  final String? tooltip;
  final Widget? child;
  final bool enabled;

  /// A small 24px icon trigger for dense, pointer-driven layouts (such as
  /// beside each editor block) instead of the 48px touch target.
  final bool compact;

  @override
  State<AdaptiveMenu> createState() => _AdaptiveMenuState();
}

class _AdaptiveMenuState extends State<AdaptiveMenu> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Widget _button(VoidCallback? onPressed) => widget.child == null
      ? IconButton(
          focusNode: _focusNode,
          icon: Icon(adaptiveMoreIcon(context)),
          onPressed: onPressed,
          iconSize: widget.compact ? 18 : null,
          padding: widget.compact ? EdgeInsets.zero : null,
          constraints: widget.compact
              ? const BoxConstraints.tightFor(width: 24, height: 24)
              : null,
          style: widget.compact
              ? const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                )
              : null,
        )
      : TextButton(
          focusNode: _focusNode,
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            foregroundColor: Theme.of(context).colorScheme.onSurface,
          ),
          child: widget.child!,
        );

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS) {
      return Tooltip(
        message: widget.tooltip ?? '',
        child: _button(widget.enabled ? _showActionSheet : null),
      );
    }
    if (platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux) {
      final theme = Theme.of(context);
      final apple = platform == TargetPlatform.macOS;
      return MenuAnchor(
        childFocusNode: _focusNode,
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(
            theme.colorScheme.surfaceContainer,
          ),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(4),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(apple ? 6 : 4),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
        ),
        menuChildren: [
          for (final entry in widget.entries)
            MenuItemButton(
              key: entry.key,
              onPressed: entry.onSelected,
              leadingIcon: entry.selected == null
                  ? null
                  : SizedBox(
                      width: 18,
                      child: entry.selected!
                          ? const Icon(Icons.check, size: 16)
                          : null,
                    ),
              style: ButtonStyle(
                minimumSize: const WidgetStatePropertyAll(Size(180, 30)),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 10),
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.focused) ||
                          states.contains(WidgetState.hovered)
                      ? (apple
                            ? CupertinoColors.activeBlue
                            : theme.colorScheme.primaryContainer)
                      : Colors.transparent,
                ),
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused) ||
                      states.contains(WidgetState.hovered)) {
                    return apple
                        ? Colors.white
                        : theme.colorScheme.onPrimaryContainer;
                  }
                  return entry.destructive
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurface;
                }),
              ),
              child: Semantics(
                selected: entry.selected,
                child: Text(entry.label),
              ),
            ),
        ],
        builder: (context, controller, child) => Tooltip(
          message: widget.tooltip ?? '',
          child: _button(
            widget.enabled
                ? () {
                    controller.isOpen ? controller.close() : controller.open();
                  }
                : null,
          ),
        ),
      );
    }
    return PopupMenuButton<AdaptiveMenuEntry>(
      tooltip: widget.tooltip,
      enabled: widget.enabled,
      onSelected: (entry) => entry.onSelected(),
      icon: widget.child == null ? Icon(adaptiveMoreIcon(context)) : null,
      iconSize: widget.compact ? 18 : null,
      padding: widget.compact ? EdgeInsets.zero : const EdgeInsets.all(8),
      style: widget.compact
          ? const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(24, 24)),
              fixedSize: WidgetStatePropertyAll(Size(24, 24)),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
      itemBuilder: (_) => [
        for (final entry in widget.entries)
          if (entry.selected != null)
            CheckedPopupMenuItem<AdaptiveMenuEntry>(
              key: entry.key,
              value: entry,
              checked: entry.selected!,
              child: Text(entry.label),
            )
          else
            PopupMenuItem<AdaptiveMenuEntry>(
              key: entry.key,
              value: entry,
              child: Text(entry.label),
            ),
      ],
      child: widget.child,
    );
  }

  Future<void> _showActionSheet() async {
    final selected = await showCupertinoModalPopup<AdaptiveMenuEntry>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: widget.child == null ? null : Text(widget.tooltip ?? ''),
        actions: [
          for (final entry in widget.entries)
            CupertinoActionSheetAction(
              key: entry.key,
              isDestructiveAction: entry.destructive,
              onPressed: () => Navigator.of(ctx).pop(entry),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (entry.selected == true) ...[
                    const Icon(CupertinoIcons.check_mark, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Semantics(
                      selected: entry.selected,
                      child: Text(entry.label),
                    ),
                  ),
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (mounted) selected?.onSelected();
  }
}

/// The note toolbar's platform menu with an adaptive More icon.
class AdaptiveMoreMenu extends StatelessWidget {
  const AdaptiveMoreMenu({
    required this.entries,
    this.tooltip,
    this.enabled = true,
    this.compact = false,
    super.key,
  });

  final List<AdaptiveMenuEntry> entries;
  final String? tooltip;
  final bool enabled;

  /// See [AdaptiveMenu.compact].
  final bool compact;

  @override
  Widget build(BuildContext context) => AdaptiveMenu(
    entries: entries,
    tooltip: tooltip,
    enabled: enabled,
    compact: compact,
  );
}
