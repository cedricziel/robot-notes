import 'package:meta/meta.dart';

/// Soft editor lock state on a note.
@immutable
class Lock {
  const Lock({required this.holder, required this.expiresAt});

  final String holder;
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => {
        'holder': holder,
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  factory Lock.fromJson(Map<String, dynamic> json) => Lock(
        holder: json['holder'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      );

  @override
  bool operator ==(Object other) =>
      other is Lock &&
      other.holder == holder &&
      other.expiresAt.isAtSameMomentAs(expiresAt);

  @override
  int get hashCode => Object.hash(holder, expiresAt.toUtc());
}

/// Listing-shaped metadata for a note (no content, no lock state).
@immutable
class NoteMeta {
  const NoteMeta({
    required this.id,
    required this.title,
    this.path = '',
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;

  /// Folder the note lives in, `/`-separated, no leading/trailing slash.
  /// Empty string means the vault root. Defaults to `''` so callers that
  /// pre-date the vault-structure change (and any server response that
  /// omits it) still construct a valid value.
  final String path;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'version': version,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory NoteMeta.fromJson(Map<String, dynamic> json) => NoteMeta(
        id: json['id'] as String,
        title: json['title'] as String,
        path: json['path'] as String? ?? '',
        version: json['version'] as int,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
      );

  @override
  bool operator ==(Object other) =>
      other is NoteMeta &&
      other.id == id &&
      other.title == title &&
      other.path == path &&
      other.version == version &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.updatedAt.isAtSameMomentAs(updatedAt);

  @override
  int get hashCode => Object.hash(
        id,
        title,
        path,
        version,
        createdAt.toUtc(),
        updatedAt.toUtc(),
      );
}

/// Full note shape returned by `GET /notes/{id}`.
@immutable
class Note {
  const Note({
    required this.id,
    required this.title,
    this.path = '',
    required this.content,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.lock,
    this.tags = const <String>[],
  });

  final String id;
  final String title;

  /// Folder the note lives in, `/`-separated, no leading/trailing slash.
  /// Empty string means the vault root.
  final String path;
  final String content;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Lock? lock;

  /// Computed tag set (frontmatter `tags` merged with inline `#tag` tokens;
  /// see `notes-storage`), in server-provided display casing. Empty when
  /// the server response omits the field.
  final List<String> tags;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'content': content,
        'version': version,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'lock': lock?.toJson(),
        'tags': tags,
      };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String,
        title: json['title'] as String,
        path: json['path'] as String? ?? '',
        content: json['content'] as String,
        version: json['version'] as int,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
        lock: json['lock'] == null
            ? null
            : Lock.fromJson(json['lock'] as Map<String, dynamic>),
        tags: json['tags'] == null
            ? const <String>[]
            : (json['tags'] as List).cast<String>(),
      );

  @override
  bool operator ==(Object other) =>
      other is Note &&
      other.id == id &&
      other.title == title &&
      other.path == path &&
      other.content == content &&
      other.version == version &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.updatedAt.isAtSameMomentAs(updatedAt) &&
      other.lock == lock &&
      _listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(
        id,
        title,
        path,
        content,
        version,
        createdAt.toUtc(),
        updatedAt.toUtc(),
        lock,
        Object.hashAll(tags),
      );
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Summary shape for an invite token (no API key — that lives in the
/// onboarding bundle fetched once per token).
@immutable
class InviteSummary {
  const InviteSummary({
    required this.token,
    required this.label,
    required this.createdAt,
    required this.expiresAt,
    required this.expired,
    this.burnedAt,
  });

  final String token;
  final String label;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? burnedAt;
  final bool expired;

  Map<String, dynamic> toJson() => {
        'token': token,
        'label': label,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'burned_at': burnedAt?.toUtc().toIso8601String(),
        'expired': expired,
      };

  factory InviteSummary.fromJson(Map<String, dynamic> json) => InviteSummary(
        token: json['token'] as String,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
        burnedAt: json['burned_at'] == null
            ? null
            : DateTime.parse(json['burned_at'] as String).toUtc(),
        expired: json['expired'] as bool,
      );

  @override
  bool operator ==(Object other) =>
      other is InviteSummary &&
      other.token == token &&
      other.label == label &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.expiresAt.isAtSameMomentAs(expiresAt) &&
      ((other.burnedAt == null && burnedAt == null) ||
          (other.burnedAt != null &&
              burnedAt != null &&
              other.burnedAt!.isAtSameMomentAs(burnedAt!))) &&
      other.expired == expired;

  @override
  int get hashCode => Object.hash(
        token,
        label,
        createdAt.toUtc(),
        expiresAt.toUtc(),
        burnedAt?.toUtc(),
        expired,
      );
}
