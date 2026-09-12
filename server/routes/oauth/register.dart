import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:meta/meta.dart';
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

/// Bounds on registrant-supplied fields, to keep a single malicious or
/// buggy registration from writing an unreasonably large client record.
const int _kMaxClientNameLength = 256;
const int _kMaxRedirectUris = 10;
const int _kMaxRedirectUriLength = 2048;

/// Upper bound on the raw registration body, checked before it is
/// decoded, so an oversized request never reaches `jsonDecode`.
const int _kMaxBodyBytes = 16 * 1024;

/// `POST /oauth/register` — Dynamic Client Registration (RFC 7591). Mints
/// a public or confidential client from an unauthenticated JSON request.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final body = await context.request.body();
  if (utf8.encode(body).length > _kMaxBodyBytes) {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }

  final dynamic raw;
  try {
    raw = jsonDecode(body);
  } on FormatException {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }
  if (raw is! Map<String, dynamic>) {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }

  final redirectUrisResult = _validateRedirectUris(raw['redirect_uris']);
  final redirectUris = redirectUrisResult.uris;
  if (redirectUris == null) {
    return oauthError(HttpStatus.badRequest, redirectUrisResult.error!);
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
  if (clientNameRaw is String && clientNameRaw.length > _kMaxClientNameLength) {
    return oauthError(HttpStatus.badRequest, 'invalid_client_metadata');
  }
  final clientName =
      (clientNameRaw is String && clientNameRaw.trim().isNotEmpty)
          ? clientNameRaw.trim()
          : 'mcp-client';

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

/// Outcome of [_validateRedirectUris]: either the validated list, or the
/// OAuth error code the caller should report. Kept distinct from a plain
/// nullable return because a too-long list or URI is reported as
/// `invalid_client_metadata`, while every other defect is
/// `invalid_redirect_uri`.
@immutable
class _RedirectUrisResult {
  const _RedirectUrisResult.ok(this.uris) : error = null;
  const _RedirectUrisResult.error(this.error) : uris = null;

  final List<String>? uris;
  final String? error;
}

_RedirectUrisResult _validateRedirectUris(Object? raw) {
  if (raw is! List || raw.isEmpty) {
    return const _RedirectUrisResult.error('invalid_redirect_uri');
  }
  if (raw.length > _kMaxRedirectUris) {
    return const _RedirectUrisResult.error('invalid_client_metadata');
  }
  final uris = <String>[];
  for (final entry in raw) {
    if (entry is! String) {
      return const _RedirectUrisResult.error('invalid_redirect_uri');
    }
    if (entry.length > _kMaxRedirectUriLength) {
      return const _RedirectUrisResult.error('invalid_client_metadata');
    }
    final uri = Uri.tryParse(entry);
    if (uri == null || !uri.isAbsolute) {
      return const _RedirectUrisResult.error('invalid_redirect_uri');
    }
    final allowed = uri.scheme == 'https' ||
        (uri.scheme == 'http' && _kLoopbackHosts.contains(uri.host));
    if (!allowed) {
      return const _RedirectUrisResult.error('invalid_redirect_uri');
    }
    uris.add(entry);
  }
  return _RedirectUrisResult.ok(uris);
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
