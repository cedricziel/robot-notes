import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/invite_store.dart';
import 'package:server/src/onboarding_bundle.dart';

/// `GET /invites/{token}/onboarding.txt` — single-use onboarding bundle.
///
/// First successful fetch returns 200 with the plain-text bundle and
/// atomically burns the invite. Subsequent fetches return 410 Gone.
/// Missing or expired invites return 404. Any other method is 405.
///
/// This endpoint is exempt from bearer auth (the token in the URL IS
/// the credential). It is the sole channel through which the configured
/// API key is delivered to a freshly onboarded agent.
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }

  final store = context.read<InviteStore>();
  final clock = context.read<Clock>();

  final existing = await store.get(token);
  if (existing == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'invite_not_found'},
    );
  }
  if (existing.isExpired(clock.nowUtc())) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'invite_not_found'},
    );
  }

  final Invite invite;
  try {
    invite = await store.burn(token);
  } on InviteNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'invite_not_found'},
    );
  } on AlreadyBurnedException {
    return Response.json(
      statusCode: HttpStatus.gone,
      body: const {'error': 'invite_burned'},
    );
  }

  final config = context.read<Config>();
  final scheme =
      context.request.uri.scheme.isEmpty ? 'http' : context.request.uri.scheme;
  final host = context.request.headers['host'] ?? 'localhost';
  final baseUrl = Uri.parse('$scheme://$host');

  final body = buildOnboardingBundle(
    invite: invite,
    apiKey: config.apiKey,
    baseUrl: baseUrl,
  );

  return Response(
    body: body,
    headers: const {
      HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
      HttpHeaders.cacheControlHeader: 'no-store',
    },
  );
}
