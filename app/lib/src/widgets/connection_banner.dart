import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../realtime/connection_status.dart';
import 'status_strip.dart';

/// Thin strip above a list that shows the realtime connection state.
/// Renders nothing while connected, so loaded content is undisturbed.
///
/// The visible strip sits inside a [SafeArea] (top only) so on phones it
/// is inset below the status bar; the host removes the top padding from
/// the screen below it while the banner is showing so the app bar there
/// doesn't inset a second time. The connected branch is a bare
/// [SizedBox.shrink] with no [SafeArea], because a [SafeArea] around an
/// empty box would still reserve the status-bar height.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({required this.status, super.key});

  final ValueListenable<ConnectionStatus> status;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: status,
      builder: (context, value, _) {
        return switch (value) {
          ConnectionStatus.connected => const SizedBox.shrink(),
          ConnectionStatus.reconnecting => const SafeArea(
            bottom: false,
            child: StatusStrip(
              key: Key('connection.banner'),
              dense: true,
              icon: Icons.sync,
              message: 'Reconnecting…',
              tone: StatusTone.warning,
            ),
          ),
          ConnectionStatus.stale => const SafeArea(
            bottom: false,
            child: StatusStrip(
              key: Key('connection.banner'),
              dense: true,
              icon: Icons.cloud_off,
              message: 'Connection lost — showing cached notes',
              tone: StatusTone.error,
            ),
          ),
        };
      },
    );
  }
}
