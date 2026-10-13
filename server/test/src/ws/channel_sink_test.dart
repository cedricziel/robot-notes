import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:server/src/ws/channel_sink.dart';
import 'package:test/test.dart';

class _MockSocket extends Mock implements WebSocket {}

void main() {
  late _MockSocket socket;

  setUp(() {
    socket = _MockSocket();
    when(() => socket.add(any<dynamic>())).thenReturn(null);
    when(
      () => socket.close(any<int?>(), any<String?>()),
    ).thenAnswer((_) async {});
  });

  group('ChannelWsSink', () {
    test('send forwards text frames to the underlying socket', () {
      ChannelWsSink(socket).send('hello');
      verify(() => socket.add('hello')).called(1);
    });

    test('close marks the sink closed and forwards the close code/reason', () {
      final sink = ChannelWsSink(socket)..close(4001, 'auth_failed');
      expect(sink.isClosed, isTrue);
      verify(() => socket.close(4001, 'auth_failed')).called(1);
    });

    test('send after close is a no-op', () {
      ChannelWsSink(socket)
        ..close(1000, 'bye')
        ..send('ignored');
      verifyNever(() => socket.add('ignored'));
    });

    test('close after close is a no-op', () {
      ChannelWsSink(socket)
        ..close(1000, 'a')
        ..close(1000, 'b');
      verify(() => socket.close(1000, 'a')).called(1);
      verifyNever(() => socket.close(1000, 'b'));
    });
  });
}
