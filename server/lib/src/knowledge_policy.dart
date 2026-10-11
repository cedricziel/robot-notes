import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:server/src/note_path.dart';
import 'package:server/src/oauth/metadata.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/store_support.dart';

/// Independently authorized operations on knowledge resources.
enum KnowledgeAction {
  /// Read accepted content and related metadata.
  read,

  /// Submit a proposal without changing accepted content.
  propose,

  /// Make a final human review decision.
  review,

  /// Mutate accepted content directly.
  edit,

  /// Change access, approval, or curation policy.
  policy,

  /// Erase retained accepted content permanently.
  purge,
}

/// Authentication source recorded by the server, never caller attribution.
enum KnowledgePrincipalKind {
  /// The configured operator key.
  operator,

  /// A server-issued agent credential.
  agent,

  /// An OAuth grant; elevated knowledge scopes require operator consent.
  oauth,

  /// No recorded identity, which grants no access.
  unidentified,
}

/// Trusted credential identity and permissions passed to content services.
class KnowledgePrincipal {
  const KnowledgePrincipal._(this.id, this.kind, this.scopes, this.vaultIds);

  /// Full administration remains available to the configured operator.
  const KnowledgePrincipal.operator()
      : this._('operator', KnowledgePrincipalKind.operator, const {}, const {});

  /// Missing credential identity fails closed, including ordinary notes.
  const KnowledgePrincipal.unidentified()
      : this._('', KnowledgePrincipalKind.unidentified, const {}, const {});

  /// Restores identity from an authenticated agent record.
  factory KnowledgePrincipal.agent({
    required String credentialId,
    required Set<String> scopes,
    Set<String> vaultIds = const {'default'},
  }) =>
      KnowledgePrincipal._(
        'agent:$credentialId',
        KnowledgePrincipalKind.agent,
        Set.unmodifiable(scopes),
        Set.unmodifiable(vaultIds),
      );

  /// Restores identity from a server-issued OAuth grant, across refreshes.
  factory KnowledgePrincipal.oauth({
    required String grantId,
    required Set<String> scopes,
    Set<String> vaultIds = const {'default'},
  }) =>
      KnowledgePrincipal._(
        'oauth:$grantId',
        KnowledgePrincipalKind.oauth,
        Set.unmodifiable(scopes),
        Set.unmodifiable(vaultIds),
      );

  /// Stable qualified credential ID, independent of actor headers.
  final String id;

  /// Immutable authentication source.
  final KnowledgePrincipalKind kind;

  /// Explicit server-granted capabilities.
  final Set<String> scopes;

  /// Explicit vault grants; vault management never implies knowledge authority.
  final Set<String> vaultIds;

  /// Whether the selected vault is permitted by the recorded grant.
  bool canAccessVault(String id) =>
      kind == KnowledgePrincipalKind.operator ||
      scopes.contains(kScopeVaultsManage) ||
      vaultIds.contains(id);

  /// Whether the operator or recorded grant has a specific capability.
  bool hasScope(String scope) =>
      kind == KnowledgePrincipalKind.operator || scopes.contains(scope);

  /// Whether direct human actions can be authorized by an elevated scope.
  bool get canActAsHuman =>
      kind == KnowledgePrincipalKind.operator ||
      kind == KnowledgePrincipalKind.oauth;
}

/// A resource path resolved from server storage, or a prospective folder.
class KnowledgeTarget {
  /// Resolves a note's policy using its recorded ID and folder path.
  KnowledgeTarget.note(String id, String path)
      : noteId = id.toLowerCase(),
        path = sanitizedPathSegments(path).join('/'),
        collection = null;

  /// Resolves inherited folder rules, including a prospective note location.
  KnowledgeTarget.folder(String path)
      : noteId = null,
        path = sanitizedPathSegments(path).join('/'),
        collection = null;

  /// Uses the archive collection, independently of digest or actor names.
  KnowledgeTarget.evidenceArchive()
      : noteId = null,
        path = '',
        collection = 'evidence_archive';

  /// Explicit collection resource; null for notes and folder targets.
  final String? collection;

  /// Canonical note ID; null for folder and prospective note targets.
  final String? noteId;

  /// Canonical folder path inside one selected vault.
  final String path;
}

/// Explicit overlays; omitted fields inherit without opening access.
class KnowledgePolicyPatch {
  /// Freezes access lists. Empty sets deny; '*' remains capability-gated.
  KnowledgePolicyPatch({
    this.curated,
    this.approval,
    Map<KnowledgeAction, Set<String>> access = const {},
  }) : access = Map.unmodifiable({
          for (final entry in access.entries)
            entry.key: Set<String>.unmodifiable(entry.value),
        }) {
    if (approval != null &&
        approval != 'human' &&
        approval != 'evidence_no_conflict') {
      throw const FormatException('Invalid approval mode');
    }
    if (!access.values.expand((ids) => ids).every(_isPrincipalId)) {
      throw const FormatException('Invalid access principal ID');
    }
  }

  /// Rejects malformed or unknown policy fields before publication.
  factory KnowledgePolicyPatch.fromJson(Map<String, dynamic> json) {
    if (!json.keys.every(const {'curated', 'approval', 'access'}.contains) ||
        (json['curated'] != null && json['curated'] is! bool) ||
        (json['approval'] != null && json['approval'] is! String) ||
        (json['access'] != null && json['access'] is! Map<String, dynamic>)) {
      throw const FormatException('Invalid policy overlay');
    }
    final access = <KnowledgeAction, Set<String>>{};
    final rawAccess = json['access'] as Map<String, dynamic>? ?? {};
    for (final entry in rawAccess.entries) {
      final matches = KnowledgeAction.values.where((a) => a.name == entry.key);
      if (matches.isEmpty || entry.value is! List<dynamic>) {
        throw const FormatException('Invalid policy access action');
      }
      final values = entry.value as List<dynamic>;
      if (!values.every((dynamic value) => value is String)) {
        throw const FormatException('Invalid policy access list');
      }
      access[matches.single] = values.cast<String>().toSet();
    }
    return KnowledgePolicyPatch(
      curated: json['curated'] as bool?,
      approval: json['approval'] as String?,
      access: access,
    );
  }

  /// Null inherits whether this resource is curated knowledge.
  final bool? curated;

  /// Null inherits human or conservative evidence-based approval policy.
  final String? approval;

  /// Only listed actions override ancestor access lists.
  final Map<KnowledgeAction, Set<String>> access;

  /// Deterministic sidecar representation without content or credentials.
  Map<String, dynamic> toJson() => {
        if (curated != null) 'curated': curated,
        if (approval != null) 'approval': approval,
        if (access.isNotEmpty)
          'access': {
            for (final action in KnowledgeAction.values)
              if (access.containsKey(action))
                action.name: access[action]!.toList()..sort(),
          },
      };
}

bool _isPrincipalId(String value) =>
    value == '*' ||
    value == 'operator' ||
    RegExp(r'^(agent|oauth):[A-Za-z0-9_-]+$').hasMatch(value);

/// Resolved rules from vault, ancestor folders, and a note overlay.
class EffectiveKnowledgePolicy {
  EffectiveKnowledgePolicy._({
    required this.curated,
    required this.approval,
    required Map<KnowledgeAction, Set<String>> access,
  }) : access = Map.unmodifiable(access);

  /// Ordinary notes stay compatible unless explicitly designated curated.
  final bool curated;

  /// Automatic acceptance still requires the proposal service's checks.
  final String approval;

  /// Missing action lists allow access only when the exact capability permits.
  final Map<KnowledgeAction, Set<String>> access;

  /// Stable effective-rule fingerprint, including the resolved folder path.
  String fingerprint(KnowledgeTarget target) => hashSecret(
        jsonEncode({
          'path': target.path,
          'collection': target.collection,
          'note_id': target.noteId,
          ...KnowledgePolicyPatch(
            curated: curated,
            approval: approval,
            access: access,
          ).toJson(),
        }),
      );
}

/// Durable server policy outside editable Markdown and disposable indexes.
class KnowledgePolicyStore {
  /// Does not read policy until load succeeds; malformed policy fails closed.
  KnowledgePolicyStore({required this.file});

  /// Isolated in-memory defaults for explicitly scoped standalone components.
  KnowledgePolicyStore.memory()
      : file = File(''),
        _loaded = true,
        _persistent = false;

  /// Per-vault sidecar file; no policy data belongs in ordinary note content.
  final File file;
  final _mutex = KeyedMutex();
  final Object _lockZone = Object();
  final _changes = StreamController<int>.broadcast(sync: true);
  Map<String, KnowledgePolicyPatch> _folders = {};
  Map<String, KnowledgePolicyPatch> _notes = {};
  Map<String, KnowledgePolicyPatch> _collections = {};
  bool _loaded = false;
  bool _persistent = true;
  int _revision = 0;

  /// Monotonic policy generation, persisted before readers observe changes.
  int get revision => _revision;

  /// Lets live subscriptions recalculate their access after policy publication.
  Stream<int> get changes => _changes.stream;

  /// Loads the full policy atomically; malformed records never default open.
  Future<void> load() async {
    if (!_persistent) return;
    if (!file.existsSync()) {
      _loaded = true;
      return;
    }
    final dynamic raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic> ||
        raw['version'] != 1 ||
        raw['revision'] is! int ||
        (raw['revision'] as int) < 0 ||
        raw['folders'] is! Map<String, dynamic> ||
        raw['notes'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid persisted knowledge policy');
    }
    final folders = _parseOverlays(raw['folders'] as Map<String, dynamic>);
    final notes = _parseOverlays(raw['notes'] as Map<String, dynamic>);
    if (raw['collections'] != null &&
        raw['collections'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid collection policy');
    }
    final collections =
        _parseOverlays(raw['collections'] as Map<String, dynamic>? ?? {});
    if (!collections.keys.every(const {'evidence_archive'}.contains)) {
      throw const FormatException('Unknown policy collection');
    }
    for (final path in folders.keys) {
      if (sanitizedPathSegments(path).join('/') != path) {
        throw const FormatException('Non-canonical policy folder');
      }
    }
    if (!notes.keys.every((id) => id.isNotEmpty && id == id.toLowerCase())) {
      throw const FormatException('Non-canonical policy note ID');
    }
    _folders = folders;
    _notes = notes;
    _collections = collections;
    _revision = raw['revision'] as int;
    _loaded = true;
  }

  /// Serializes policy changes and accepted mutations, with nested operations.
  Future<T> withMutationLock<T>(Future<T> Function() body) {
    final existing = Zone.current[_lockZone];
    if (existing is _PolicyMutationLease && existing.active) return body();
    return _mutex.run('policy', () async {
      final lease = _PolicyMutationLease();
      try {
        return await runZoned(body, zoneValues: {_lockZone: lease});
      } finally {
        lease.active = false;
      }
    });
  }

  /// Resolves fields independently through all ancestors and note overrides.
  EffectiveKnowledgePolicy effective(KnowledgeTarget target) {
    if (!_loaded) throw StateError('Knowledge policy must be loaded');
    var curated = false;
    var approval = 'human';
    final access = <KnowledgeAction, Set<String>>{};
    final parts = target.path.isEmpty ? <String>[] : target.path.split('/');
    final overlays = [
      for (var length = 0; length <= parts.length; length++)
        _folders[parts.take(length).join('/')],
      if (target.noteId != null) _notes[target.noteId],
      if (target.collection != null) _collections[target.collection],
    ];
    for (final overlay in overlays) {
      if (overlay == null) continue;
      curated = overlay.curated ?? curated;
      approval = overlay.approval ?? approval;
      access.addAll(overlay.access);
    }
    return EffectiveKnowledgePolicy._(
      curated: curated,
      approval: approval,
      access: access,
    );
  }

  /// Resolves a proposed overlay without publishing it to concurrent readers.
  EffectiveKnowledgePolicy effectiveAfter(
    KnowledgeTarget resource,
    KnowledgeTarget changedTarget,
    KnowledgePolicyPatch? patch,
  ) {
    final preview = KnowledgePolicyStore.memory()
      .._folders = {..._folders}
      .._notes = {..._notes}
      .._collections = {..._collections};
    final overlays = changedTarget.collection != null
        ? preview._collections
        : changedTarget.noteId != null
            ? preview._notes
            : preview._folders;
    final key =
        changedTarget.collection ?? changedTarget.noteId ?? changedTarget.path;
    if (patch == null) {
      overlays.remove(key);
    } else {
      overlays[key] = patch;
    }
    final result = preview.effective(resource);
    unawaited(preview.dispose());
    return result;
  }

  /// Returns only the explicit overlay on this resource.
  KnowledgePolicyPatch? local(KnowledgeTarget target) =>
      target.collection != null
          ? _collections[target.collection]
          : target.noteId != null
              ? _notes[target.noteId]
              : _folders[target.path];

  Future<void> _put(KnowledgeTarget target, KnowledgePolicyPatch? patch) async {
    final folders = {..._folders};
    final notes = {..._notes};
    final collections = {..._collections};
    if (target.collection != null) {
      if (patch == null) {
        collections.remove(target.collection);
      } else {
        collections[target.collection!] = patch;
      }
    } else if (target.noteId == null) {
      if (patch == null) {
        folders.remove(target.path);
      } else {
        folders[target.path] = patch;
      }
    } else {
      if (patch == null) {
        notes.remove(target.noteId);
      } else {
        notes[target.noteId!] = patch;
      }
    }
    final nextRevision = revision + 1;
    if (_persistent) {
      await atomicWriteJsonFile(file, {
        'version': 1,
        'revision': nextRevision,
        'folders': {
          for (final entry in folders.entries) entry.key: entry.value.toJson(),
        },
        'collections': {
          for (final entry in collections.entries)
            entry.key: entry.value.toJson(),
        },
        'notes': {
          for (final entry in notes.entries) entry.key: entry.value.toJson(),
        },
      });
    }
    _folders = folders;
    _notes = notes;
    _collections = collections;
    _revision = nextRevision;
    _changes.add(nextRevision);
  }

  Map<String, KnowledgePolicyPatch> _parseOverlays(Map<String, dynamic> raw) {
    final result = <String, KnowledgePolicyPatch>{};
    for (final entry in raw.entries) {
      if (entry.value is! Map<String, dynamic>) {
        throw const FormatException('Invalid persisted policy overlay');
      }
      result[entry.key] =
          KnowledgePolicyPatch.fromJson(entry.value as Map<String, dynamic>);
    }
    return result;
  }

  /// Releases live policy observers when the vault closes.
  Future<void> dispose() => _changes.close();
}

class _PolicyMutationLease {
  bool active = true;
}

/// Denied content operations carry no accepted content in their error.
class KnowledgeAccessDeniedException implements Exception {
  /// Records only the attempted operation.
  const KnowledgeAccessDeniedException(this.action);

  /// Operation whose capability, role, or access rule was denied.
  final KnowledgeAction action;

  @override
  String toString() => 'KnowledgeAccessDeniedException: ${action.name}';
}

/// Shared authorization for every content adapter and accepted write service.
class NoteAuthorizationService {
  /// Uses one loaded store for both policy resolution and mutation locking.
  NoteAuthorizationService({
    required this.store,
    this.vaultId = 'default',
    this.beforeMutation,
    this.beforePolicyPublish,
  });

  /// Server-selected vault, independent of any caller-supplied actor.
  final String vaultId;

  /// Blocks policy writes if accepted history recovery requires a restart.
  final Future<void> Function()? beforeMutation;

  /// Captures accepted history before a newly curated policy is visible.
  Future<void> Function(KnowledgeTarget target, KnowledgePolicyPatch? patch)?
      beforePolicyPublish;

  /// Authoritative policy for the selected vault.
  final KnowledgePolicyStore store;

  /// Checks exact capabilities and role before effective action access lists.
  bool allows(
    KnowledgePrincipal principal,
    KnowledgeAction action,
    KnowledgeTarget target,
  ) {
    if (principal.kind == KnowledgePrincipalKind.unidentified) return false;
    final policy = store.effective(target);
    if (!principal.canAccessVault(vaultId)) return false;
    if (principal.kind == KnowledgePrincipalKind.operator) return true;
    final readers = policy.access[KnowledgeAction.read];
    final canRead = principal.hasScope('notes:read') &&
        (readers == null ||
            readers.contains('*') ||
            readers.contains(principal.id));
    if (action != KnowledgeAction.read && !canRead) return false;
    final authorized = switch (action) {
      KnowledgeAction.read => principal.hasScope('notes:read'),
      KnowledgeAction.propose => principal.hasScope(kScopeKnowledgePropose),
      KnowledgeAction.review =>
        principal.canActAsHuman && principal.hasScope(kScopeKnowledgeReview),
      KnowledgeAction.edit => principal.hasScope('notes:write') &&
          (!policy.curated ||
              (principal.canActAsHuman &&
                  principal.hasScope(kScopeKnowledgeEdit))),
      KnowledgeAction.policy =>
        principal.canActAsHuman && principal.hasScope(kScopeKnowledgePolicy),
      KnowledgeAction.purge =>
        principal.canActAsHuman && principal.hasScope(kScopeKnowledgePurge),
    };
    final access = policy.access[action];
    return authorized &&
        (access == null ||
            access.contains('*') ||
            access.contains(principal.id));
  }

  /// Throws before a denied operation can read or change accepted content.
  void require(
    KnowledgePrincipal principal,
    KnowledgeAction action,
    KnowledgeTarget target,
  ) {
    if (!allows(principal, action, target)) {
      throw KnowledgeAccessDeniedException(action);
    }
  }

  /// Checks rights while preventing intervening policy changes.
  Future<T> runMutation<T>(
    KnowledgePrincipal principal,
    KnowledgeAction action,
    KnowledgeTarget target,
    Future<T> Function() body,
  ) =>
      store.withMutationLock(() async {
        require(principal, action, target);
        await beforeMutation?.call();
        return body();
      });

  /// Publishes a folder overlay only with trusted human policy authority.
  Future<void> putFolderPolicy(
    KnowledgePrincipal principal,
    String path,
    KnowledgePolicyPatch patch,
  ) =>
      _putPolicy(principal, KnowledgeTarget.folder(path), patch);

  /// Publishes a note overlay using its server-resolved current folder path.
  Future<void> putNotePolicy(
    KnowledgePrincipal principal,
    KnowledgeTarget target,
    KnowledgePolicyPatch patch,
  ) {
    if (target.noteId == null) throw ArgumentError('Note target required');
    return _putPolicy(principal, target, patch);
  }

  Future<void> _putPolicy(
    KnowledgePrincipal principal,
    KnowledgeTarget target,
    KnowledgePolicyPatch patch,
  ) =>
      changePolicy(principal, target, patch);

  /// Replaces or resets one overlay under the vault mutation lock.
  Future<void> changePolicy(
    KnowledgePrincipal principal,
    KnowledgeTarget target,
    KnowledgePolicyPatch? patch, {
    int? ifMatch,
  }) =>
      runMutation(principal, KnowledgeAction.policy, target, () async {
        if (ifMatch != null && ifMatch != store.revision) {
          throw KnowledgePolicyConflict(store.revision);
        }
        await beforePolicyPublish?.call(target, patch);
        await store._put(target, patch);
      });

  /// Policy inspection requires human policy authority at the selected target.
  Map<String, Object?> inspectPolicy(
    KnowledgePrincipal principal,
    KnowledgeTarget target,
  ) {
    require(principal, KnowledgeAction.policy, target);
    final effective = store.effective(target);
    return {
      'target': {
        'kind': target.collection != null
            ? 'collection'
            : target.noteId != null
                ? 'note'
                : 'folder',
        if (target.collection != null) 'name': target.collection,
        if (target.noteId != null) 'id': target.noteId,
        'path': target.path,
      },
      'local_policy': store.local(target)?.toJson(),
      'effective_policy': KnowledgePolicyPatch(
        curated: effective.curated,
        approval: effective.approval,
        access: effective.access,
      ).toJson(),
      'policy_revision': store.revision,
      'policy_fingerprint': effective.fingerprint(target),
      'allowed_actions': permissions(principal, target)['allowed_actions'],
    };
  }

  /// Publishes the archive collection overlay independently of note identities.
  Future<void> putEvidenceArchivePolicy(
    KnowledgePrincipal principal,
    KnowledgePolicyPatch patch,
  ) =>
      _putPolicy(principal, KnowledgeTarget.evidenceArchive(), patch);

  /// Requires selected-vault and collection read access before digest lookup.
  void requireEvidenceRead(KnowledgePrincipal principal, String digest) {
    if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid evidence digest');
    }
    require(principal, KnowledgeAction.read, KnowledgeTarget.evidenceArchive());
  }

  /// Historical sources need both current/tombstone and retained-location access.
  void requireHistoricalRead(
    KnowledgePrincipal principal,
    String id,
    String retainedPath,
    String currentOrLastTombstonePath,
  ) {
    require(
      principal,
      KnowledgeAction.read,
      KnowledgeTarget.note(id, currentOrLastTombstonePath),
    );
    require(
      principal,
      KnowledgeAction.read,
      KnowledgeTarget.note(id, retainedPath),
    );
  }

  /// Returns own actions without disclosing another principal's access lists.
  Map<String, Object?> permissions(
    KnowledgePrincipal principal,
    KnowledgeTarget target,
  ) {
    final policy = store.effective(target);
    return {
      'id': target.noteId,
      'path': target.path,
      'curated': policy.curated,
      'approval': policy.approval,
      'policy_revision': store.revision,
      'policy_fingerprint': policy.fingerprint(target),
      'principal_kind': principal.kind.name,
      'allowed_actions': [
        for (final action in KnowledgeAction.values)
          if (allows(principal, action, target)) action.name,
      ],
      'requires_human_approval': policy.approval == 'human',
    };
  }
}

/// A policy writer used a superseded server generation.
class KnowledgePolicyConflict implements Exception {
  /// Records the current generation without exposing protected content.
  const KnowledgePolicyConflict(this.currentRevision);

  /// Generation that superseded the caller's conditional write.
  final int currentRevision;
}
