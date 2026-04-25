import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/lock_manager.dart';

/// `POST /notes/{id}/lock`   — acquire (or refresh) the soft editor lock.
/// `PUT  /notes/{id}/lock`   — heartbeat an existing lock to extend its TTL.
/// `DELETE /notes/{id}/lock` — release the lock (idempotent for the holder).
Future<Response> onRequest(RequestContext context, String id) async {
  switch (context.request.method) {
    case HttpMethod.post:
      return _acquire(context, id);
    case HttpMethod.put:
      return _heartbeat(context, id);
    case HttpMethod.delete:
      return _release(context, id);
    case HttpMethod.get:
    case HttpMethod.head:
    case HttpMethod.options:
    case HttpMethod.patch:
      return Response.json(
        statusCode: HttpStatus.methodNotAllowed,
        body: const {'error': 'method_not_allowed'},
      );
  }
}

Future<Response> _acquire(RequestContext context, String id) async {
  final actor = context.read<Actor>();
  final lockManager = context.read<LockManager>();
  try {
    final lock = await lockManager.acquire(noteId: id, actor: actor.name);
    return Response.json(
      body: {
        'holder': lock.holder,
        'expires_at': lock.expiresAt.toUtc().toIso8601String(),
      },
    );
  } on LockedException catch (e) {
    return _lockedResponse(e);
  }
}

Future<Response> _heartbeat(RequestContext context, String id) async {
  final actor = context.read<Actor>();
  final lockManager = context.read<LockManager>();
  try {
    final lock = await lockManager.heartbeat(noteId: id, actor: actor.name);
    return Response.json(
      body: {
        'holder': lock.holder,
        'expires_at': lock.expiresAt.toUtc().toIso8601String(),
      },
    );
  } on LockedException catch (e) {
    return _lockedResponse(e);
  } on LockNotFoundException {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: const {'error': 'lock_not_found'},
    );
  }
}

Future<Response> _release(RequestContext context, String id) async {
  final actor = context.read<Actor>();
  final lockManager = context.read<LockManager>();
  try {
    await lockManager.release(noteId: id, actor: actor.name);
    return Response(statusCode: HttpStatus.noContent);
  } on LockedException catch (e) {
    return _lockedResponse(e);
  }
}

Response _lockedResponse(LockedException e) => Response.json(
      statusCode: HttpStatus.locked,
      body: {
        'error': 'locked',
        'lock': {
          'holder': e.current.holder,
          'expires_at': e.current.expiresAt.toUtc().toIso8601String(),
        },
      },
    );
