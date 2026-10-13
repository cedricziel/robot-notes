// Adapted from package:shelf_web_socket's WebSocketHandler.
// Copyright 2014, the Dart project authors.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
//       copyright notice, this list of conditions and the following
//       disclaimer in the documentation and/or other materials provided
//       with the distribution.
//     * Neither the name of Google LLC nor the names of its
//       contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import 'dart:convert';
import 'dart:io';

import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:shelf/shelf.dart';

/// Upgrades HTTP/1.1 WebSocket requests to native server sockets.
///
/// The native transport permits server protocol close codes such as 1003 and
/// 1008, which package:web_socket's browser-compatible adapter rejects.
Handler serverWebSocketHandler(void Function(WebSocket socket) onConnection) {
  return (request) {
    final connection = request.headers['connection'];
    final isUpgrade = connection != null &&
        connection
            .toLowerCase()
            .split(',')
            .map((token) => token.trim())
            .contains('upgrade');
    if (request.method != 'GET' ||
        !isUpgrade ||
        request.headers['upgrade']?.toLowerCase() != 'websocket') {
      return Response.notFound('Only WebSocket connections are supported.');
    }
    final version = request.headers['sec-websocket-version'];
    if (version == null) {
      return Response.badRequest(body: 'Missing Sec-WebSocket-Version.');
    }
    if (version != '13') return Response.notFound('Unsupported version.');
    if (request.protocolVersion != '1.1') {
      return Response.badRequest(body: 'Unexpected HTTP version.');
    }
    final key = request.headers['sec-websocket-key'];
    if (key == null) {
      return Response.badRequest(body: 'Missing Sec-WebSocket-Key.');
    }
    if (!request.canHijack) {
      throw ArgumentError('The server must support request hijacking.');
    }
    request.hijack((channel) {
      final socket = channel.sink;
      if (socket is! Socket) {
        throw ArgumentError('The upgraded connection must be a Socket.');
      }
      socket.add(
        utf8.encode(
          'HTTP/1.1 101 Switching Protocols\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Accept: ${WebSocketChannel.signKey(key)}\r\n\r\n',
        ),
      );
      onConnection(WebSocket.fromUpgradedSocket(socket, serverSide: true));
    });
  };
}
