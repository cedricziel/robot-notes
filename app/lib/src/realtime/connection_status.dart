import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ws_client.dart';

enum ConnectionStatus {
  connected,

  /// Offline; the client's reconnect loop is running.
  reconnecting,

  /// Offline for longer than the client's stale threshold, so the data on
  /// screen may be out of date.
  stale,
}

/// Folds [RobotNotesWsClient.events] into a single [ConnectionStatus] the
/// UI can render. Starts [ConnectionStatus.reconnecting] because the client
/// has not connected yet when it is created.
///
/// [onStaleReconnect] fires when a connection is re-established after the
/// outage went stale, so the owner can refetch over HTTP.
class ConnectionStatusController extends ValueNotifier<ConnectionStatus> {
  ConnectionStatusController({
    required Stream<RealtimeEvent> events,
    this.onStaleReconnect,
  }) : super(ConnectionStatus.reconnecting) {
    _sub = events.listen(_onEvent);
  }

  final VoidCallback? onStaleReconnect;
  late final StreamSubscription<RealtimeEvent> _sub;

  void _onEvent(RealtimeEvent event) {
    switch (event) {
      case WsConnected():
        final wasStale = value == ConnectionStatus.stale;
        value = ConnectionStatus.connected;
        if (wasStale) onStaleReconnect?.call();
      case WsDisconnected():
        if (value != ConnectionStatus.stale) {
          value = ConnectionStatus.reconnecting;
        }
      case WsStale():
        value = ConnectionStatus.stale;
      case RealtimeMessage():
        break;
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}
