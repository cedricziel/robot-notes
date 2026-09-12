import 'dart:async';

import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  late StreamController<RealtimeEvent> events;
  late ConnectionStatusController status;
  late int staleReconnects;

  Future<void> emit(RealtimeEvent event) async {
    events.add(event);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    events = StreamController<RealtimeEvent>.broadcast();
    staleReconnects = 0;
    status = ConnectionStatusController(
      events: events.stream,
      onStaleReconnect: () => staleReconnects += 1,
    );
    addTearDown(() async {
      status.dispose();
      await events.close();
    });
  });

  test(
    'starts reconnecting until the first connection is established',
    () async {
      expect(status.value, ConnectionStatus.reconnecting);

      await emit(const WsConnected());

      expect(status.value, ConnectionStatus.connected);
    },
  );

  test('a dropped connection is reconnecting until it comes back', () async {
    await emit(const WsConnected());
    await emit(const WsDisconnected());
    expect(status.value, ConnectionStatus.reconnecting);

    await emit(const WsConnected());
    expect(status.value, ConnectionStatus.connected);
    expect(staleReconnects, 0);
  });

  test('a long outage is stale and stays stale while still offline', () async {
    await emit(const WsConnected());
    await emit(const WsDisconnected());
    await emit(const WsStale());
    expect(status.value, ConnectionStatus.stale);

    await emit(const WsDisconnected());
    expect(status.value, ConnectionStatus.stale);
    expect(staleReconnects, 0);
  });

  test('reconnecting after a stale outage reports it', () async {
    await emit(const WsConnected());
    await emit(const WsDisconnected());
    await emit(const WsStale());
    await emit(const WsConnected());

    expect(status.value, ConnectionStatus.connected);
    expect(staleReconnects, 1);
  });

  test('protocol messages do not change the status', () async {
    await emit(const WsConnected());
    await emit(const RealtimeMessage(AuthOkMsg()));
    expect(status.value, ConnectionStatus.connected);
  });

  test('dispose stops listening to the stream', () async {
    final own = StreamController<RealtimeEvent>();
    addTearDown(own.close);
    ConnectionStatusController(events: own.stream).dispose();

    await Future<void>.delayed(Duration.zero);
    expect(own.hasListener, isFalse);
  });
}
