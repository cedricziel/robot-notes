import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/bounded_body.dart';
import 'package:server/src/config.dart';
import 'package:server/src/mcp/json_rpc.dart';
import 'package:server/src/mcp/mcp_handler.dart';
import 'package:server/src/mcp/mcp_http.dart';
import 'package:server/src/mcp/principal.dart';

/// `POST /mcp` — the sole Streamable HTTP MCP entrypoint.
///
/// Checks run in a fixed order, each before the next so an invalid request
/// is refused as cheaply as possible: method, `Origin`, `MCP-Protocol-
/// Version`, body size, then the JSON-RPC body itself. Authentication and
/// the [McpPrincipal] it produces are handled by
/// `routes/mcp/_middleware.dart` before this handler ever runs.
///
/// The transport is stateless: no `Mcp-Session-Id` is ever read or
/// emitted, and every response is a plain JSON body — never
/// `text/event-stream`.
Future<Response> onRequest(RequestContext context) async {
  final request = context.request;
  if (request.method != HttpMethod.post) {
    return mcpMethodNotAllowed();
  }

  final origin = request.headers['origin'];
  if (origin != null &&
      !isAllowedMcpOrigin(origin, context.read<Config>().publicUrl)) {
    return mcpForbidden();
  }

  final protocolVersion = request.headers['mcp-protocol-version'];
  if (protocolVersion != null &&
      !kSupportedProtocolVersions.contains(protocolVersion)) {
    return mcpUnsupportedProtocolVersion();
  }

  final bodyBytes = await readBoundedBody(request, maxBytes: kMaxMcpBodyBytes);
  if (bodyBytes == null) return mcpPayloadTooLarge();

  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bodyBytes));
  } on FormatException catch (e) {
    annotateMcpError('parse_error');
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: jsonRpcError(null, kParseError, 'Invalid JSON: $e'),
    );
  }

  final JsonRpcMessage message;
  try {
    message = JsonRpcMessage.parse(decoded);
  } on JsonRpcInvalidParamsAtParse catch (e) {
    annotateMcpError('invalid_params');
    return Response.json(body: jsonRpcError(e.id, kInvalidParams, e.message));
  } on JsonRpcInvalidRequest catch (e) {
    annotateMcpError('invalid_request');
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: jsonRpcError(null, kInvalidRequest, e.message),
    );
  }

  final handler = context.read<McpHandler>();
  final principal = context.read<McpPrincipal>();
  final result = await handler.handle(message, principal);
  if (result == null) {
    return Response(statusCode: HttpStatus.accepted);
  }
  return Response.json(body: result);
}
