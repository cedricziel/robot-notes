import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

/// Base type for everything [RobotNotesClient] throws so callers can write
/// a single `on ApiException` and still drill down for specific cases.
@immutable
sealed class ApiException implements Exception {
  const ApiException({required this.statusCode, this.message});

  final int statusCode;
  final String? message;

  @override
  String toString() => '$runtimeType(status: $statusCode'
      '${message == null ? '' : ', message: $message'})';
}

/// 401 — bearer key was missing or rejected. Bubble this to the UI as
/// "your key is no longer valid; please re-run setup".
class UnauthorizedException extends ApiException {
  const UnauthorizedException({super.message}) : super(statusCode: 401);
}

/// 404 — note (or other addressable resource) does not exist on this server.
class NotFoundException extends ApiException {
  const NotFoundException({super.message}) : super(statusCode: 404);
}

/// 400 — malformed request. The server's `message` field is the only
/// caller-actionable signal; we plumb it through verbatim.
class BadRequestException extends ApiException {
  const BadRequestException({super.message}) : super(statusCode: 400);
}

/// 409 — `If-Match: <version>` was stale. The server returns the current
/// note state in the body so the UI can show a 3-way diff or "discard mine /
/// take theirs" prompt without a second round-trip.
class VersionConflictException extends ApiException {
  const VersionConflictException({required this.current, super.message})
      : super(statusCode: 409);

  final Note current;
}

/// 423 — somebody else holds the editor lock. Includes their identity and
/// when the lock expires, so the UI can show "Alice is editing (3:42 left)".
class LockedException extends ApiException {
  const LockedException({required this.lock, super.message})
      : super(statusCode: 423);

  final Lock lock;
}

/// Anything else non-2xx that we don't model specifically. Keeps a single
/// well-known type so callers don't have to handle raw `http.Response`s.
class ApiServerException extends ApiException {
  const ApiServerException({required super.statusCode, super.message});
}
