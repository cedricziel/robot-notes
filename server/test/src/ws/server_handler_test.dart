import 'package:server/src/ws/server_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final handler = serverWebSocketHandler((_) {
    fail('Invalid requests must not open a WebSocket.');
  });
  final uri = Uri.parse('http://localhost/ws');
  const headers = {
    'Connection': 'Upgrade',
    'Upgrade': 'websocket',
    'Sec-WebSocket-Version': '13',
    'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
  };

  test('ordinary HTTP requests return 404', () async {
    final response = await handler(Request('GET', uri));
    expect(response.statusCode, 404);
  });

  test('WebSocket upgrades require GET', () async {
    final response = await handler(Request('POST', uri, headers: headers));
    expect(response.statusCode, 404);
  });

  test('WebSocket upgrades require HTTP/1.1', () async {
    final response = await handler(
      Request('GET', uri, headers: headers, protocolVersion: '1.0'),
    );
    expect(response.statusCode, 400);
  });

  test('WebSocket upgrades require a version header', () async {
    final response = await handler(
      Request(
        'GET',
        uri,
        headers: {
          'Connection': 'Upgrade',
          'Upgrade': 'websocket',
          'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
        },
      ),
    );
    expect(response.statusCode, 400);
  });

  test('WebSocket upgrades require version 13', () async {
    final response = await handler(
      Request('GET', uri, headers: {...headers, 'Sec-WebSocket-Version': '12'}),
    );
    expect(response.statusCode, 404);
  });

  test('WebSocket upgrades require a handshake key', () async {
    final response = await handler(
      Request(
        'GET',
        uri,
        headers: {
          'Connection': 'Upgrade',
          'Upgrade': 'websocket',
          'Sec-WebSocket-Version': '13',
        },
      ),
    );
    expect(response.statusCode, 400);
  });
}
