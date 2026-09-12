import 'package:server/src/mcp/json_rpc.dart';
import 'package:test/test.dart';

void main() {
  group('JsonRpcMessage.parse', () {
    test('parses a request', () {
      final msg = JsonRpcMessage.parse({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ping',
        'params': {'a': 1},
      });
      expect(msg, isA<JsonRpcRequest>());
      final req = msg as JsonRpcRequest;
      expect(req.id, 1);
      expect(req.method, 'ping');
      expect(req.params, {'a': 1});
    });

    test('parses a request with a string id and no params', () {
      final msg = JsonRpcMessage.parse({
        'jsonrpc': '2.0',
        'id': 'abc',
        'method': 'ping',
      });
      final req = msg as JsonRpcRequest;
      expect(req.id, 'abc');
      expect(req.params, isNull);
    });

    test('parses a notification (no id)', () {
      final msg = JsonRpcMessage.parse({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(msg, isA<JsonRpcNotification>());
      final notif = msg as JsonRpcNotification;
      expect(notif.method, 'notifications/initialized');
      expect(notif.params, isNull);
    });

    test('parses a client response carrying a result', () {
      final msg = JsonRpcMessage.parse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {'ok': true},
      });
      expect(msg, isA<JsonRpcResponse>());
      final resp = msg as JsonRpcResponse;
      expect(resp.id, 1);
      expect(resp.result, {'ok': true});
      expect(resp.error, isNull);
    });

    test('parses a client response carrying an error', () {
      final msg = JsonRpcMessage.parse({
        'jsonrpc': '2.0',
        'id': 1,
        'error': {'code': -1, 'message': 'nope'},
      });
      final resp = msg as JsonRpcResponse;
      expect(resp.error, {'code': -1, 'message': 'nope'});
    });

    test('rejects a batch array', () {
      expect(
        () => JsonRpcMessage.parse([
          {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
        ]),
        throwsA(isA<JsonRpcInvalidRequest>()),
      );
    });

    test('rejects a non-object', () {
      expect(
        () => JsonRpcMessage.parse('hello'),
        throwsA(isA<JsonRpcInvalidRequest>()),
      );
      expect(
        () => JsonRpcMessage.parse(42),
        throwsA(isA<JsonRpcInvalidRequest>()),
      );
      expect(
        () => JsonRpcMessage.parse(null),
        throwsA(isA<JsonRpcInvalidRequest>()),
      );
    });

    test('rejects a missing jsonrpc field', () {
      expect(
        () => JsonRpcMessage.parse({'id': 1, 'method': 'ping'}),
        throwsA(isA<JsonRpcInvalidRequest>()),
      );
    });

    test('rejects the wrong jsonrpc version', () {
      expect(
        () =>
            JsonRpcMessage.parse({'jsonrpc': '1.0', 'id': 1, 'method': 'ping'}),
        throwsA(isA<JsonRpcInvalidRequest>()),
      );
    });

    test(
      'a request with array params throws an invalid-params error '
      'echoing the id, not a batch-shaped invalid request',
      () {
        expect(
          () => JsonRpcMessage.parse({
            'jsonrpc': '2.0',
            'id': 5,
            'method': 'ping',
            'params': [1, 2, 3],
          }),
          throwsA(
            isA<JsonRpcInvalidParamsAtParse>().having(
              (e) => e.id,
              'id',
              5,
            ),
          ),
        );
      },
    );

    test(
      'a notification with array params is accepted with params dropped',
      () {
        final msg = JsonRpcMessage.parse({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
          'params': [1, 2, 3],
        });
        expect(msg, isA<JsonRpcNotification>());
        expect((msg as JsonRpcNotification).params, isNull);
      },
    );
  });

  group('envelope builders', () {
    test('jsonRpcResult echoes id and wraps result', () {
      expect(jsonRpcResult(7, {'x': 1}), {
        'jsonrpc': '2.0',
        'id': 7,
        'result': {'x': 1},
      });
    });

    test('jsonRpcError echoes id and builds an error object', () {
      expect(jsonRpcError(7, -32601, 'nope'), {
        'jsonrpc': '2.0',
        'id': 7,
        'error': {'code': -32601, 'message': 'nope'},
      });
    });

    test('jsonRpcError includes data when supplied', () {
      final env = jsonRpcError(null, -32602, 'bad', data: {'field': 'id'});
      expect(env['error'], {
        'code': -32602,
        'message': 'bad',
        'data': {'field': 'id'},
      });
    });
  });

  test('error code constants match the JSON-RPC 2.0 spec', () {
    expect(kParseError, -32700);
    expect(kInvalidRequest, -32600);
    expect(kMethodNotFound, -32601);
    expect(kInvalidParams, -32602);
    expect(kInternalError, -32603);
  });
}
