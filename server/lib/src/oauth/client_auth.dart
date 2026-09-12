import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:meta/meta.dart';
import 'package:server/src/oauth/client_store.dart';
import 'package:server/src/oauth/oauth_records.dart';

/// Result of [authenticateClient]: either the resolved [client], or a
/// failure carrying the OAuth `error` code the caller should report, plus
/// (for a `client_secret_basic` mismatch) the `WWW-Authenticate` header
/// value the caller should attach to the 401 response.
@immutable
class ClientAuthResult {
  /// A successfully authenticated [client].
  const ClientAuthResult.success(this.client)
      : error = null,
        wwwAuthenticate = null;

  /// A failed authentication, reported as [error].
  const ClientAuthResult.failure(this.error, {this.wwwAuthenticate})
      : client = null;

  /// The authenticated client, or `null` on failure.
  final OAuthClient? client;

  /// The OAuth error code (`invalid_client`) on failure, or `null` on
  /// success.
  final String? error;

  /// The `WWW-Authenticate` header value to attach to the 401 response,
  /// set only when the registered method is `client_secret_basic`.
  final String? wwwAuthenticate;

  /// Whether authentication succeeded.
  bool get isSuccess => client != null;
}

const String _kBasicRealm = 'Basic realm="robot-notes"';

/// Authenticates the OAuth client making the request, following the
/// method it registered with at `POST /oauth/register`:
///
/// - `none`: [form] must carry `client_id`; any `client_secret` present is
///   ignored.
/// - `client_secret_post`: [form] must carry `client_id` and the correct
///   `client_secret`.
/// - `client_secret_basic`: the request must carry an `Authorization:
///   Basic` header with the correct credentials.
///
/// The client id is read from the `Authorization: Basic` header when
/// present, otherwise from `form['client_id']`. An unknown client id, or a
/// method mismatch, yields [ClientAuthResult.failure] with
/// `invalid_client`.
Future<ClientAuthResult> authenticateClient(
  RequestContext context,
  Map<String, String> form,
) async {
  final store = context.read<ClientStore>();
  final basic = _tryParseBasic(context.request.headers['authorization']);

  final clientId = basic?.clientId ?? form['client_id'];
  if (clientId == null || clientId.isEmpty) {
    return const ClientAuthResult.failure('invalid_client');
  }
  final client = await store.get(clientId);
  if (client == null) {
    return const ClientAuthResult.failure('invalid_client');
  }

  switch (client.tokenEndpointAuthMethod) {
    case 'none':
      return ClientAuthResult.success(client);
    case 'client_secret_post':
      final secret = form['client_secret'];
      if (secret == null || !store.verifySecret(client, secret)) {
        return const ClientAuthResult.failure('invalid_client');
      }
      return ClientAuthResult.success(client);
    case 'client_secret_basic':
      if (basic == null || !store.verifySecret(client, basic.clientSecret)) {
        return const ClientAuthResult.failure(
          'invalid_client',
          wwwAuthenticate: _kBasicRealm,
        );
      }
      return ClientAuthResult.success(client);
    default:
      return const ClientAuthResult.failure('invalid_client');
  }
}

@immutable
class _BasicCredentials {
  const _BasicCredentials(this.clientId, this.clientSecret);
  final String clientId;
  final String clientSecret;
}

_BasicCredentials? _tryParseBasic(String? header) {
  if (header == null) return null;
  // The auth scheme token is case-insensitive (RFC 7235 §2.1); only the
  // base64 payload after it is case-sensitive.
  const prefix = 'basic ';
  if (header.length < prefix.length ||
      header.substring(0, prefix.length).toLowerCase() != prefix) {
    return null;
  }
  final String decoded;
  try {
    decoded = utf8.decode(base64.decode(header.substring(prefix.length)));
  } on FormatException {
    return null;
  }
  final sep = decoded.indexOf(':');
  if (sep < 0) return null;
  // RFC 6749 §2.3.1: the client id and secret are each encoded with the
  // application/x-www-form-urlencoded algorithm before being joined with
  // ":" and base64-encoded, so they must be form-urldecoded back before
  // use — not just base64-decoded.
  try {
    return _BasicCredentials(
      Uri.decodeQueryComponent(decoded.substring(0, sep)),
      Uri.decodeQueryComponent(decoded.substring(sep + 1)),
    );
  } on FormatException {
    return null;
  } catch (e) {
    // `Uri.decodeQueryComponent` throws a plain `ArgumentError` (not a
    // `FormatException`) for some malformed percent-escapes, even though
    // the input is an untrusted header rather than a programming mistake;
    // narrow the catch to that case and let anything else propagate.
    if (e is ArgumentError) return null;
    rethrow;
  }
}
