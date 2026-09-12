import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/oauth_response.dart';

const List<String> _kSupportedAuthMethods = [
  'none',
  'client_secret_post',
  'client_secret_basic',
];
const List<String> _kSupportedGrantTypes = [
  'authorization_code',
  'refresh_token',
];
const List<String> _kSupportedResponseTypes = ['code'];
const List<String> _kLoopbackHosts = ['localhost', '127.0.0.1', '::1'];

/// `POST /oauth/register` — Dynamic Client Registration (RFC 7591). Mints
/// a public or confidential client from an unauthenticated JSON request.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final dynamic raw;
  try {
    raw = await context.request.json();
  } on FormatException {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }
  if (raw is! Map<String, dynamic>) {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }

  final redirectUris = _validateRedirectUris(raw['redirect_uris']);
  if (redirectUris == null) {
    return oauthError(HttpStatus.badRequest, 'invalid_redirect_uri');
  }

  final authMethod = (raw['token_endpoint_auth_method'] as String?) ?? 'none';
  if (!_kSupportedAuthMethods.contains(authMethod)) {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }

  final grantTypes = _validateSubset(
    raw['grant_types'],
    _kSupportedGrantTypes,
    ['authorization_code', 'refresh_token'],
  );
  if (grantTypes == null) {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }

  final responseTypes = _validateSubset(
    raw['response_types'],
    _kSupportedResponseTypes,
    ['code'],
  );
  if (responseTypes == null) {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }

  final clientNameRaw = raw['client_name'];
  final clientName =
      (clientNameRaw is String && clientNameRaw.trim().isNotEmpty)
          ? clientNameRaw.trim()
          : 'Unnamed client';

  final store = context.read<ClientStore>();
  final registered = await store.register(
    clientName: clientName,
    redirectUris: redirectUris,
    tokenEndpointAuthMethod: authMethod,
    grantTypes: grantTypes,
    responseTypes: responseTypes,
  );
  final client = registered.client;

  return Response.json(
    statusCode: HttpStatus.created,
    headers: kNoStoreHeaders,
    body: {
      'client_id': client.clientId,
      'client_id_issued_at':
          client.createdAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      'redirect_uris': client.redirectUris,
      'client_name': client.clientName,
      'token_endpoint_auth_method': client.tokenEndpointAuthMethod,
      'grant_types': client.grantTypes,
      'response_types': client.responseTypes,
      if (registered.clientSecret != null) ...{
        'client_secret': registered.clientSecret,
        'client_secret_expires_at': 0,
      },
    },
  );
}

List<String>? _validateRedirectUris(Object? raw) {
  if (raw is! List || raw.isEmpty) return null;
  final uris = <String>[];
  for (final entry in raw) {
    if (entry is! String) return null;
    final uri = Uri.tryParse(entry);
    if (uri == null || !uri.isAbsolute) return null;
    final allowed = uri.scheme == 'https' ||
        (uri.scheme == 'http' && _kLoopbackHosts.contains(uri.host));
    if (!allowed) return null;
    uris.add(entry);
  }
  return uris;
}

/// Validates that [raw] (defaulting to [fallback] when absent) is a list
/// of strings drawn from [supported].
List<String>? _validateSubset(
  Object? raw,
  List<String> supported,
  List<String> fallback,
) {
  if (raw == null) return fallback;
  if (raw is! List || raw.isEmpty) return null;
  final values = <String>[];
  for (final entry in raw) {
    if (entry is! String || !supported.contains(entry)) return null;
    values.add(entry);
  }
  return values;
}
