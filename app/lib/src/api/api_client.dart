import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import '../config/app_config.dart';
import 'api_exceptions.dart';

/// One page of `GET /notes` results plus the cursor (or `null` if exhausted).
@immutable
class NotePage {
  const NotePage({required this.items, required this.limit, this.nextCursor});

  final List<NoteMeta> items;
  final int limit;
  final String? nextCursor;
}

/// One row from `GET /search`. Lives here rather than `shared/` because the
/// server's search route emits `rank` only as a derived score, not part of the
/// note model itself.
@immutable
class SearchHit {
  const SearchHit({
    required this.id,
    required this.title,
    required this.snippet,
    required this.rank,
  });

  final String id;
  final String title;
  final String snippet;
  final double rank;

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        id: json['id'] as String,
        title: json['title'] as String,
        snippet: json['snippet'] as String,
        rank: (json['rank'] as num).toDouble(),
      );
}

/// HTTP client for the robot-notes v1 API.
///
/// Stamped with bearer auth + `X-Actor` on every request, surfaces typed
/// exceptions (Unauthorized, NotFound, VersionConflict, Locked, BadRequest,
/// ApiServerException) instead of raw status codes, and parses JSON into
/// `package:shared` DTOs.
///
/// One client = one config. Re-create on config change. The underlying
/// [http.Client] is injectable so tests can drive a [MockClient] without
/// hitting the network.
class RobotNotesClient {
  RobotNotesClient({
    required AppConfig config,
    http.Client? httpClient,
  })  : _config = config.normalized(),
        _http = httpClient ?? http.Client();

  final AppConfig _config;
  final http.Client _http;

  /// Closes the underlying [http.Client]. Safe to call multiple times.
  void close() => _http.close();

  Map<String, String> get _baseHeaders => <String, String>{
        'Authorization': 'Bearer ${_config.apiKey}',
        'X-Actor': _config.actor,
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse('${_config.baseUrl}$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        ...query,
      },
    );
  }

  Future<NotePage> listNotes({String? after, int? limit}) async {
    final query = <String, String>{
      if (after != null) 'after': after,
      if (limit != null) 'limit': '$limit',
    };
    final res = await _http.get(_uri('/notes', query), headers: _baseHeaders);
    final body = _ok(res);
    final items = (body['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(NoteMeta.fromJson)
        .toList(growable: false);
    return NotePage(
      items: items,
      limit: body['limit'] as int,
      nextCursor: body['next_cursor'] as String?,
    );
  }

  Future<Note> getNote(String id) async {
    final res = await _http.get(_uri('/notes/$id'), headers: _baseHeaders);
    return Note.fromJson(_ok(res));
  }

  Future<Note> createNote({required String title, String content = ''}) async {
    final res = await _http.post(
      _uri('/notes'),
      headers: <String, String>{
        ..._baseHeaders,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, Object?>{'title': title, 'content': content}),
    );
    return Note.fromJson(_ok(res));
  }

  Future<Note> updateNote({
    required String id,
    required String title,
    required String content,
    required int ifMatch,
  }) async {
    final res = await _http.put(
      _uri('/notes/$id'),
      headers: <String, String>{
        ..._baseHeaders,
        'Content-Type': 'application/json',
        'If-Match': '$ifMatch',
      },
      body: jsonEncode(<String, Object?>{'title': title, 'content': content}),
    );
    return Note.fromJson(_ok(res));
  }

  Future<void> deleteNote(String id) async {
    final res = await _http.delete(_uri('/notes/$id'), headers: _baseHeaders);
    _ensureNoContent(res);
  }

  Future<Lock> acquireLock(String id) async {
    final res = await _http.post(
      _uri('/notes/$id/lock'),
      headers: _baseHeaders,
    );
    return Lock.fromJson(_ok(res));
  }

  Future<Lock> heartbeatLock(String id) async {
    final res = await _http.put(
      _uri('/notes/$id/lock'),
      headers: _baseHeaders,
    );
    return Lock.fromJson(_ok(res));
  }

  Future<void> releaseLock(String id) async {
    final res = await _http.delete(
      _uri('/notes/$id/lock'),
      headers: _baseHeaders,
    );
    _ensureNoContent(res);
  }

  Future<List<SearchHit>> search({required String q, int? limit}) async {
    final query = <String, String>{
      'q': q,
      if (limit != null) 'limit': '$limit',
    };
    final res = await _http.get(_uri('/search', query), headers: _baseHeaders);
    final body = _ok(res);
    return (body['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(SearchHit.fromJson)
        .toList(growable: false);
  }

  /// Decodes a 2xx JSON body, or throws the appropriate typed exception.
  Map<String, dynamic> _ok(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return const <String, dynamic>{};
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        throw ApiServerException(
          statusCode: res.statusCode,
          message: 'expected JSON object, got ${decoded.runtimeType}',
        );
      }
      return decoded;
    }
    throw _errorFor(res);
  }

  void _ensureNoContent(http.Response res) {
    if (res.statusCode == 204) return;
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    throw _errorFor(res);
  }

  ApiException _errorFor(http.Response res) {
    Map<String, dynamic>? body;
    if (res.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } on FormatException {
        body = null;
      }
    }
    final message = body?['message'] as String?;

    switch (res.statusCode) {
      case 400:
        return BadRequestException(message: message);
      case 401:
        return UnauthorizedException(message: message);
      case 404:
        return NotFoundException(message: message);
      case 409:
        final current = body?['current'];
        if (current is Map<String, dynamic>) {
          // The 409 body for PUT /notes/{id} omits `lock`, which is fine —
          // Note.fromJson treats a missing `lock` key as `null`.
          return VersionConflictException(
            current: Note.fromJson(current),
            message: message,
          );
        }
        return ApiServerException(
          statusCode: 409,
          message: message ?? 'version_conflict body missing "current"',
        );
      case 423:
        final lock = body?['lock'];
        if (lock is Map<String, dynamic>) {
          return LockedException(
            lock: Lock.fromJson(lock),
            message: message,
          );
        }
        return ApiServerException(
          statusCode: 423,
          message: message ?? 'locked body missing "lock"',
        );
      default:
        return ApiServerException(
          statusCode: res.statusCode,
          message: message,
        );
    }
  }
}
