import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/invite_store.dart';

/// `GET  /invites` — list all invites with `expired` flags.
/// `POST /invites` — mint a new invite.
Future<Response> onRequest(RequestContext context) async {
  final method = context.request.method;
  switch (method) {
    case HttpMethod.get:
      return _list(context);
    case HttpMethod.post:
      return _mint(context);
    case HttpMethod.delete:
    case HttpMethod.head:
    case HttpMethod.options:
    case HttpMethod.patch:
    case HttpMethod.put:
      return Response.json(
        statusCode: HttpStatus.methodNotAllowed,
        body: const {'error': 'method_not_allowed'},
      );
  }
}

Future<Response> _list(RequestContext context) async {
  final store = context.read<InviteStore>();
  final summaries = await store.list();
  return Response.json(
    body: {
      'items': [for (final s in summaries) s.toJson()],
    },
  );
}

Future<Response> _mint(RequestContext context) async {
  final dynamic raw;
  try {
    raw = await context.request.json();
  } on FormatException {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'bad_request', 'message': 'body must be JSON'},
    );
  }
  if (raw is! Map<String, dynamic>) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'body must be a JSON object',
      },
    );
  }
  final labelRaw = raw['label'];
  if (labelRaw != null && labelRaw is! String) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'label must be a string',
      },
    );
  }
  final label = ((labelRaw as String?) ?? 'agent').trim();
  if (label.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {
        'error': 'bad_request',
        'message': 'label must be non-empty',
      },
    );
  }

  final ttlRaw = raw['ttl_seconds'];
  Duration? ttl;
  if (ttlRaw != null) {
    if (ttlRaw is! int || ttlRaw <= 0) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: const {
          'error': 'bad_request',
          'message': 'ttl_seconds must be a positive integer',
        },
      );
    }
    if (ttlRaw > kMaxInviteTtl.inSeconds) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: const {'error': 'invalid_ttl'},
      );
    }
    ttl = Duration(seconds: ttlRaw);
  }

  final store = context.read<InviteStore>();
  final invite = await store.mint(label: label, ttl: ttl);
  // Read clock to compute the response payload's `expired` flag.
  final now = context.read<Clock>().nowUtc();
  final summary = invite.toSummary(now: now);

  final scheme =
      context.request.uri.scheme.isEmpty ? 'http' : context.request.uri.scheme;
  final host = context.request.headers['host'] ?? 'localhost';
  final base = '$scheme://$host';
  final url = '$base/invites/${invite.token}/onboarding.txt';

  return Response.json(
    statusCode: HttpStatus.created,
    body: {
      'token': invite.token,
      'label': invite.label,
      'url': url,
      'expires_at': invite.expiresAt.toIso8601String(),
      'expired': summary.expired,
      'single_use': true,
    },
  );
}
