import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../realtime/ws_client.dart';

/// One folder node in the sidebar's rendered tree. [path] is the full
/// `/`-separated path from the vault root; [name] is just this node's own
/// segment, for display. [noteCount] is the number of notes that live
/// directly in [path] (0 for a purely intermediate folder synthesized to
/// give a deeper folder a parent to nest under).
@immutable
class FolderTreeNode {
  const FolderTreeNode({
    required this.path,
    required this.name,
    required this.noteCount,
    this.children = const <FolderTreeNode>[],
  });

  final String path;
  final String name;
  final int noteCount;
  final List<FolderTreeNode> children;
}

/// Builds a nested [FolderTreeNode] forest from the flat folder list
/// `GET /notes/tree` returns. The server only reports folders that
/// directly contain at least one note, so an intermediate folder with no
/// notes of its own (e.g. `Projects` when only `Projects/Alpha` has notes)
/// does not appear in [folders] — this function synthesizes it (with
/// `noteCount: 0`) purely so `Alpha` has somewhere to nest.
///
/// The root folder (`path: ''`) is not part of the nested tree — it has no
/// name of its own to render as a node — and is surfaced separately via
/// [FolderTreeState.rootNoteCount].
List<FolderTreeNode> buildFolderTree(List<TreeFolder> folders) {
  final counts = <String, int>{
    for (final f in folders)
      if (f.path.isNotEmpty) f.path: f.noteCount,
  };

  // Every path prefix that needs a node: each folder's own path plus every
  // intermediate segment above it.
  final allPaths = <String>{};
  for (final path in counts.keys) {
    final segments = path.split('/');
    var acc = '';
    for (final segment in segments) {
      acc = acc.isEmpty ? segment : '$acc/$segment';
      allPaths.add(acc);
    }
  }

  // Build deepest-first so each node's children are already fully built (as
  // entries under `childrenByPath[path]`) by the time the node itself is
  // constructed; ties broken alphabetically for deterministic sibling order.
  final sorted = allPaths.toList()
    ..sort((a, b) {
      final depthCompare = '/'
          .allMatches(b)
          .length
          .compareTo('/'.allMatches(a).length);
      return depthCompare != 0 ? depthCompare : a.compareTo(b);
    });

  final childrenByPath = <String, List<FolderTreeNode>>{};
  final roots = <FolderTreeNode>[];
  for (final path in sorted) {
    final children = List<FolderTreeNode>.of(
      childrenByPath[path] ?? const <FolderTreeNode>[],
    )..sort((a, b) => a.name.compareTo(b.name));
    final node = FolderTreeNode(
      path: path,
      name: path.split('/').last,
      noteCount: counts[path] ?? 0,
      children: List<FolderTreeNode>.unmodifiable(children),
    );
    final slash = path.lastIndexOf('/');
    if (slash == -1) {
      roots.add(node);
    } else {
      final parent = path.substring(0, slash);
      (childrenByPath[parent] ??= <FolderTreeNode>[]).add(node);
    }
  }
  roots.sort((a, b) => a.name.compareTo(b.name));
  return roots;
}

/// Snapshot of [FolderTreeController] state.
@immutable
class FolderTreeState {
  const FolderTreeState({
    this.roots = const <FolderTreeNode>[],
    this.rootNoteCount,
    this.isLoading = false,
    this.error,
  });

  static const empty = FolderTreeState();

  final List<FolderTreeNode> roots;

  /// Note count for the vault root (`path: ''`), or `null` if the server
  /// did not report any root-level notes.
  final int? rootNoteCount;
  final bool isLoading;
  final Object? error;

  FolderTreeState copyWith({
    List<FolderTreeNode>? roots,
    Object? rootNoteCount = _sentinel,
    bool? isLoading,
    Object? error = _sentinel,
  }) => FolderTreeState(
    roots: roots ?? this.roots,
    rootNoteCount: identical(rootNoteCount, _sentinel)
        ? this.rootNoteCount
        : rootNoteCount as int?,
    isLoading: isLoading ?? this.isLoading,
    error: identical(error, _sentinel) ? this.error : error,
  );
}

const Object _sentinel = Object();

/// Drives the folder tree sidebar. Pulls `GET /notes/tree` and re-fetches
/// whenever a live `changed` event could change which folders have notes
/// in them (`moved`, `created`, `deleted` — `updated` never moves a note,
/// so it is not a reason to re-fetch).
class FolderTreeController extends ValueNotifier<FolderTreeState> {
  FolderTreeController({
    required RobotNotesClient api,
    Stream<RealtimeEvent>? events,
  }) : _api = api,
       super(FolderTreeState.empty) {
    if (events != null) {
      _sub = events.listen(_onEvent);
    }
  }

  final RobotNotesClient _api;
  StreamSubscription<RealtimeEvent>? _sub;
  bool _disposed = false;

  Future<void> refresh() async {
    if (_disposed) return;
    value = value.copyWith(isLoading: true, error: null);
    try {
      final tree = await _api.getTree();
      if (_disposed) return;
      int? rootCount;
      for (final f in tree.folders) {
        if (f.path.isEmpty) {
          rootCount = f.noteCount;
          break;
        }
      }
      value = FolderTreeState(
        roots: buildFolderTree(tree.folders),
        rootNoteCount: rootCount,
        isLoading: false,
      );
    } catch (e) {
      if (_disposed) return;
      value = value.copyWith(isLoading: false, error: e);
    }
  }

  void _onEvent(RealtimeEvent event) {
    if (event is! RealtimeMessage) return;
    final msg = event.message;
    if (msg is! ChangedEvent) return;
    switch (msg.action) {
      case ChangeAction.moved:
      case ChangeAction.created:
      case ChangeAction.deleted:
        unawaited(refresh());
      case ChangeAction.updated:
        break;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
