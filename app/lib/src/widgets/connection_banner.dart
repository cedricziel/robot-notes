import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../realtime/connection_status.dart';

/// Thin strip above a list that shows the realtime connection state.
/// Renders nothing while connected, so loaded content is undisturbed.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({required this.status, super.key});

  final ValueListenable<ConnectionStatus> status;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: status,
      builder: (context, value, _) {
        final scheme = Theme.of(context).colorScheme;
        return switch (value) {
          ConnectionStatus.connected => const SizedBox.shrink(),
          ConnectionStatus.reconnecting => _Strip(
            icon: Icons.sync,
            message: 'Reconnecting…',
            background: scheme.secondaryContainer,
            foreground: scheme.onSecondaryContainer,
          ),
          ConnectionStatus.stale => _Strip(
            icon: Icons.cloud_off,
            message: 'Connection lost — showing cached notes',
            background: scheme.errorContainer,
            foreground: scheme.onErrorContainer,
          ),
        };
      },
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    required this.icon,
    required this.message,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String message;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('connection.banner'),
      color: background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: TextStyle(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}
