import 'package:flutter/material.dart';

/// Semantic tone of a [StatusStrip]; maps to a [ColorScheme] container pair
/// so every strip in the app picks its colors the same way.
enum StatusTone {
  /// Neutral information (someone else is editing, autosave state).
  info,

  /// Something the user should notice but that isn't a failure
  /// (reconnecting, lock lost).
  warning,

  /// A failed request or a lost connection.
  error,
}

/// The one full-width status strip used above lists, in the note view, on
/// the setup card, and for the realtime connection state. Replaces the
/// four near-identical colored `Material` + `Padding` + `Row` stacks the
/// screens used to each define for themselves.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    required this.message,
    this.tone = StatusTone.info,
    this.icon,
    this.leading,
    this.action,
    this.rounded = false,
    this.dense = false,
    super.key,
  });

  final String message;
  final StatusTone tone;

  /// Optional icon rendered before the message. Ignored when [leading] is
  /// supplied.
  final IconData? icon;

  /// Arbitrary leading widget (an avatar, a spinner). Takes precedence
  /// over [icon].
  final Widget? leading;

  /// Optional trailing action, typically a [TextButton].
  final Widget? action;

  /// Rounded corners for a strip that floats inside a card rather than
  /// spanning the full width of a screen.
  final bool rounded;

  /// Tighter vertical padding, for a one-line strip under an app bar.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (tone) {
      StatusTone.info => (scheme.surfaceContainerHighest, scheme.onSurface),
      StatusTone.warning => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      StatusTone.error => (scheme.errorContainer, scheme.onErrorContainer),
    };
    final lead =
        leading ??
        (icon == null ? null : Icon(icon, size: 18, color: foreground));
    return Material(
      color: background,
      borderRadius: rounded ? BorderRadius.circular(8) : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          dense ? 6 : 10,
          action == null ? 16 : 8,
          dense ? 6 : 10,
        ),
        child: Row(
          children: [
            if (lead != null) ...[lead, const SizedBox(width: 12)],
            Expanded(
              child: Text(message, style: TextStyle(color: foreground)),
            ),
            if (action != null) ...[const SizedBox(width: 8), action!],
          ],
        ),
      ),
    );
  }
}
