import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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

/// One entry of an [AdaptiveMoreMenu].
class AdaptiveMenuEntry {
  const AdaptiveMenuEntry({
    required this.label,
    required this.onSelected,
    this.key,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onSelected;
  final Key? key;

  /// Painted red in an iOS action sheet; no effect on the Material menu.
  final bool destructive;
}

/// The trailing "more" button of an app bar, with the platform's own idea
/// of a contextual menu behind it: an iOS action sheet sliding up from the
/// bottom (with a Cancel button, as Apple's HIG expects for a short list of
/// actions on a phone) and a Material popup menu everywhere else, macOS
/// included — a sheet is a phone idiom; a Mac expects a menu near the
/// pointer.
class AdaptiveMoreMenu extends StatelessWidget {
  const AdaptiveMoreMenu({required this.entries, this.tooltip, super.key});

  final List<AdaptiveMenuEntry> entries;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return IconButton(
        tooltip: tooltip,
        icon: Icon(adaptiveMoreIcon(context)),
        onPressed: () => _showActionSheet(context),
      );
    }
    return PopupMenuButton<void>(
      tooltip: tooltip,
      icon: Icon(adaptiveMoreIcon(context)),
      itemBuilder: (_) => [
        for (final entry in entries)
          PopupMenuItem<void>(
            key: entry.key,
            onTap: entry.onSelected,
            child: Text(entry.label),
          ),
      ],
    );
  }

  Future<void> _showActionSheet(BuildContext context) async {
    final selected = await showCupertinoModalPopup<AdaptiveMenuEntry>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          for (final entry in entries)
            CupertinoActionSheetAction(
              key: entry.key,
              isDestructiveAction: entry.destructive,
              onPressed: () => Navigator.of(ctx).pop(entry),
              child: Text(entry.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
    // Run the handler only once the sheet has gone: a handler that opens a
    // dialog of its own (Delete, Move) must not stack it on the sheet.
    selected?.onSelected();
  }
}
