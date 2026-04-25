import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/ws/channel_sink.dart';
import 'package:test/test.dart';

class _MockChannel extends Mock implements WebSocketChannel {}

class _MockSink extends Mock implements WebSocketSink {}

void main() {
  late _MockChannel channel;
  late _MockSink wsSink;

  setUp(() {
    channel = _MockChannel();
    wsSink = _MockSink();
    when(() => channel.sink).thenReturn(wsSink);
    when(() => wsSink.add(any<dynamic>())).thenReturn(null);
    when(
      () => wsSink.close(any<int?>(), any<String?>()),
    ).thenAnswer((_) async {});
  });

  group('ChannelWsSink', () {
    test('send forwards text frames to the underlying channel sink', () {
      ChannelWsSink(channel).send('hello');
      verify(() => wsSink.add('hello')).called(1);
    });

    test('close marks the sink closed and forwards the close code/reason', () {
      final sink = ChannelWsSink(channel)..close(4001, 'auth_failed');
      expect(sink.isClosed, isTrue);
      verify(() => wsSink.close(4001, 'auth_failed')).called(1);
    });

    test('send after close is a no-op', () {
      ChannelWsSink(channel)
        ..close(1000, 'bye')
        ..send('ignored');
      verifyNever(() => wsSink.add('ignored'));
    });

    test('close after close is a no-op', () {
      ChannelWsSink(channel)
        ..close(1000, 'a')
        ..close(1000, 'b');
      verify(() => wsSink.close(1000, 'a')).called(1);
      verifyNever(() => wsSink.close(1000, 'b'));
    });
  });
}
