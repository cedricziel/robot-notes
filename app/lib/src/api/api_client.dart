import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
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

/// One folder from `GET /notes/tree`: a folder that directly contains at
/// least one note, plus how many. Intermediate folders with no notes of
/// their own are not part of the server response — callers that want them
/// (e.g. to render a full tree) derive them from the flat [path]s.
@immutable
class TreeFolder {
  const TreeFolder({required this.path, required this.noteCount});

  final String path;
  final int noteCount;

  factory TreeFolder.fromJson(Map<String, dynamic> json) => TreeFolder(
    path: json['path'] as String,
    noteCount: json['note_count'] as int,
  );
}

/// `GET /notes/tree` response: the flat list of folders that directly
/// contain notes.
@immutable
class NotesTree {
  const NotesTree({required this.folders});

  final List<TreeFolder> folders;
}

/// `POST /notes/attachments` response: where an uploaded file ended up
/// and how the server sees it.
@immutable
class AttachmentUploadResult {
  const AttachmentUploadResult({
    required this.path,
    required this.filename,
    required this.size,
    required this.contentType,
  });

  /// Folder the attachment was stored in.
  final String path;

  /// Sanitized filename the attachment was stored under.
  final String filename;

  /// Size of the stored file, in bytes.
  final int size;

  /// Content-type the server recorded for the upload.
  final String contentType;

  factory AttachmentUploadResult.fromJson(Map<String, dynamic> json) =>
      AttachmentUploadResult(
        path: json['path'] as String,
        filename: json['filename'] as String,
        size: json['size'] as int,
        contentType: json['content_type'] as String,
      );
}

/// One entry of `GET /notes/{id}/backlinks`: a note that links to the note
/// being viewed.
@immutable
class BacklinkHit {
  const BacklinkHit({
    required this.id,
    required this.title,
    required this.snippet,
  });

  final String id;
  final String title;
  final String snippet;

  factory BacklinkHit.fromJson(Map<String, dynamic> json) => BacklinkHit(
    id: json['id'] as String,
    title: json['title'] as String,
    snippet: json['snippet'] as String,
  );
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
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String snippet;
  final double rank;

  /// When the note was last updated.
  final DateTime updatedAt;

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
    id: json['id'] as String,
    title: json['title'] as String,
    snippet: json['snippet'] as String,
    rank: (json['rank'] as num).toDouble(),
    updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
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
  RobotNotesClient({required AppConfig config, http.Client? httpClient})
    : _config = config.normalized(),
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
      queryParameters: <String, String>{...base.queryParameters, ...query},
    );
  }

  Future<NotePage> listNotes({
    String? after,
    int? limit,
    String? sort,
    String? path,
    String? tag,
  }) async {
    final query = <String, String>{
      'after': ?after,
      if (limit != null) 'limit': '$limit',
      'sort': ?sort,
      'path': ?path,
      'tag': ?tag,
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

  /// `GET /notes/tree` — folders that directly contain at least one note.
  Future<NotesTree> getTree() async {
    final res = await _http.get(_uri('/notes/tree'), headers: _baseHeaders);
    final body = _ok(res);
    final folders = (body['folders'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(TreeFolder.fromJson)
        .toList(growable: false);
    return NotesTree(folders: folders);
  }

  /// `GET /notes/{id}/backlinks` — notes that link to [id].
  Future<List<BacklinkHit>> getBacklinks(String id) async {
    final res = await _http.get(
      _uri('/notes/$id/backlinks'),
      headers: _baseHeaders,
    );
    final body = _ok(res);
    return (body['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(BacklinkHit.fromJson)
        .toList(growable: false);
  }

  Future<Note> getNote(String id) async {
    final res = await _http.get(_uri('/notes/$id'), headers: _baseHeaders);
    return Note.fromJson(_ok(res));
  }

  Future<Note> createNote({
    required String title,
    String content = '',
    String path = '',
  }) async {
    final res = await _http.post(
      _uri('/notes'),
      headers: <String, String>{
        ..._baseHeaders,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, Object?>{
        'title': title,
        'content': content,
        'path': path,
      }),
    );
    return Note.fromJson(_ok(res));
  }

  /// `POST /notes/tree` — creates an empty folder (and any missing
  /// intermediate folders) at [path], persisted via a marker file so it
  /// survives a restart even with no notes in it. Idempotent: succeeds
  /// (200) if the folder already exists, whether it holds notes, a
  /// marker, or both.
  Future<void> createFolder(String path) async {
    final res = await _http.post(
      _uri('/notes/tree'),
      headers: <String, String>{
        ..._baseHeaders,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, Object?>{'path': path}),
    );
    _ok(res);
  }

  /// `POST /notes/attachments` — uploads a non-note file into [path]
  /// (the vault root when empty). A filename collision surfaces as
  /// [PathConflictException]; exceeding the server's configured max
  /// upload size surfaces as [PayloadTooLargeException].
  Future<AttachmentUploadResult> uploadFile({
    required String path,
    required String filename,
    required List<int> bytes,
    String? contentType,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/notes/attachments'))
      ..headers.addAll(_baseHeaders)
      ..fields['path'] = path
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
          contentType: contentType != null
              ? MediaType.parse(contentType)
              : null,
        ),
      );
    final streamed = await _http.send(request);
    final res = await http.Response.fromStream(streamed);
    return AttachmentUploadResult.fromJson(_ok(res));
  }

  Future<Note> updateNote({
    required String id,
    required String title,
    required String content,
    required int ifMatch,
    String? path,
  }) async {
    final res = await _http.put(
      _uri('/notes/$id'),
      headers: <String, String>{
        ..._baseHeaders,
        'Content-Type': 'application/json',
        'If-Match': '$ifMatch',
      },
      body: jsonEncode(<String, Object?>{
        'title': title,
        'content': content,
        'path': ?path,
      }),
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
    final res = await _http.put(_uri('/notes/$id/lock'), headers: _baseHeaders);
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
        if (body?['error'] == 'path_conflict') {
          return PathConflictException(message: message);
        }
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
      case 413:
        return PayloadTooLargeException(message: message);
      case 423:
        final lock = body?['lock'];
        if (lock is Map<String, dynamic>) {
          return LockedException(lock: Lock.fromJson(lock), message: message);
        }
        return ApiServerException(
          statusCode: 423,
          message: message ?? 'locked body missing "lock"',
        );
      default:
        return ApiServerException(statusCode: res.statusCode, message: message);
    }
  }
}
