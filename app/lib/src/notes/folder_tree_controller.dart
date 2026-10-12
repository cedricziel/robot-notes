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
    this.fileCount = 0,
  });

  final String path;
  final String name;
  final int noteCount;
  final int fileCount;
  final List<FolderTreeNode> children;
}

/// Builds folder hierarchy, including intermediate path segments.
///
/// The root folder (`path: ''`) is not part of the nested tree — it has no
/// name of its own to render as a node — and is surfaced separately via
/// [FolderTreeState.rootNoteCount].
List<FolderTreeNode> buildFolderTree(List<TreeFolder> folders) {
  final fileCounts = {
    for (final folder in folders) folder.path: folder.fileCount,
  };
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
    )..sort((a, b) => compareTreeLabels(a.name, a.path, b.name, b.path));
    final node = FolderTreeNode(
      path: path,
      name: path.split('/').last,
      noteCount: counts[path] ?? 0,
      fileCount: fileCounts[path] ?? 0,
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
  roots.sort((a, b) => compareTreeLabels(a.name, a.path, b.name, b.path));
  return roots;
}

int compareTreeLabels(String a, String aId, String b, String bId) {
  final label = a.toLowerCase().compareTo(b.toLowerCase());
  return label == 0 ? aId.compareTo(bId) : label;
}

@immutable
class FolderContents {
  const FolderContents({
    this.notes = const [],
    this.files = const [],
    this.nextCursor,
    this.isLoading = false,
    this.loaded = false,
    this.error,
  });
  final List<NoteMeta> notes;
  final List<VaultFile> files;
  final String? nextCursor;
  final bool isLoading;
  final bool loaded;
  final Object? error;
}

@immutable
class FolderTreeState {
  const FolderTreeState({
    this.roots = const [],
    this.rootNoteCount,
    this.isLoading = false,
    this.error,
    this.expandedPaths = const {},
    this.contents = const {},
  });
  static const empty = FolderTreeState();
  final List<FolderTreeNode> roots;
  final int? rootNoteCount;
  final bool isLoading;
  final Object? error;
  final Set<String> expandedPaths;
  final Map<String, FolderContents> contents;

  FolderTreeState copyWith({
    List<FolderTreeNode>? roots,
    Object? rootNoteCount = _sentinel,
    bool? isLoading,
    Object? error = _sentinel,
    Set<String>? expandedPaths,
    Map<String, FolderContents>? contents,
  }) => FolderTreeState(
    roots: roots ?? this.roots,
    rootNoteCount: identical(rootNoteCount, _sentinel)
        ? this.rootNoteCount
        : rootNoteCount as int?,
    isLoading: isLoading ?? this.isLoading,
    error: identical(error, _sentinel) ? this.error : error,
    expandedPaths: expandedPaths ?? this.expandedPaths,
    contents: contents ?? this.contents,
  );
}

const _sentinel = Object();

class FolderTreeController extends ValueNotifier<FolderTreeState> {
  FolderTreeController({required this.api, Stream<RealtimeEvent>? events})
    : super(FolderTreeState.empty) {
    _sub = events?.listen(_onEvent);
  }
  final RobotNotesClient api;
  StreamSubscription<RealtimeEvent>? _sub;
  bool _disposed = false;
  int _hierarchyRequest = 0;
  final Map<String, int> _requests = {};
  final Map<String, Future<void>> _pending = {};
  int _revealRequest = 0;

  Future<void> refresh({bool refreshContents = true}) async {
    if (_disposed) return;
    final request = ++_hierarchyRequest;
    value = value.copyWith(isLoading: true, error: null);
    try {
      final tree = await api.getTree();
      if (_disposed || request != _hierarchyRequest) return;
      value = value.copyWith(
        roots: buildFolderTree(tree.folders),
        rootNoteCount: tree.folders
            .where((f) => f.path.isEmpty)
            .firstOrNull
            ?.noteCount,
        isLoading: false,
      );
      if (refreshContents) {
        await Future.wait([
          for (final path in value.contents.keys.toList())
            loadFolder(path, force: true),
        ]);
      }
    } catch (e) {
      if (!_disposed && request == _hierarchyRequest) {
        value = value.copyWith(isLoading: false, error: e);
      }
    }
  }

  Future<void> expand(String path) {
    if (_disposed) return Future.value();
    value = value.copyWith(expandedPaths: {...value.expandedPaths, path});
    return loadFolder(path);
  }

  void collapse(String path) {
    if (_disposed) return;
    value = value.copyWith(
      expandedPaths: {...value.expandedPaths}..remove(path),
    );
  }

  Future<void> toggle(String path) async {
    if (value.expandedPaths.contains(path)) {
      collapse(path);
    } else {
      await expand(path);
    }
  }

  void _setContents(String path, FolderContents contents) {
    if (!_disposed) {
      value = value.copyWith(contents: {...value.contents, path: contents});
    }
  }

  Future<void> loadFolder(String path, {bool force = false}) {
    if (_disposed) return Future.value();
    if (!force) {
      if (_pending[path] != null) return _pending[path]!;
      if (value.contents[path]?.loaded == true) return Future.value();
    }
    final future = _load(path, append: false);
    _pending[path] = future;
    future.whenComplete(() {
      if (identical(_pending[path], future)) _pending.remove(path);
    });
    return future;
  }

  Future<void> loadMore(String path) {
    final contents = value.contents[path];
    if (_disposed ||
        contents == null ||
        contents.isLoading ||
        contents.nextCursor == null) {
      return Future.value();
    }
    return _load(path, append: true);
  }

  Future<void> _load(String path, {required bool append}) async {
    final previous = value.contents[path] ?? const FolderContents();
    final request = (_requests[path] ?? 0) + 1;
    _requests[path] = request;
    _setContents(
      path,
      FolderContents(
        notes: previous.notes,
        files: previous.files,
        nextCursor: previous.nextCursor,
        loaded: previous.loaded,
        isLoading: true,
      ),
    );
    try {
      final results = await Future.wait<Object>([
        api.listNotes(
          path: path,
          includeSubfolders: false,
          after: append ? previous.nextCursor : null,
        ),
        if (!append) api.listFiles(path),
      ]);
      if (_disposed || _requests[path] != request) return;
      var page = results.first as NotePage;
      final fetched = <NoteMeta>[];
      final cursors = <String>{};
      while (true) {
        if (page.items.any((n) => n.path != path)) {
          throw StateError(
            'Server does not support direct folder browsing. Update the server.',
          );
        }
        fetched.addAll(page.items);
        final cursor = page.nextCursor;
        if (append ||
            fetched.length >= previous.notes.length ||
            cursor == null) {
          break;
        }
        if (!cursors.add(cursor)) {
          throw StateError('Server repeated a folder cursor.');
        }
        page = await api.listNotes(
          path: path,
          includeSubfolders: false,
          after: cursor,
        );
        if (_disposed || _requests[path] != request) return;
      }
      final notes =
          {
              for (final n in [
                ...(append ? previous.notes : <NoteMeta>[]),
                ...fetched,
              ])
                n.id: n,
            }.values.toList()
            ..sort((a, b) => compareTreeLabels(a.title, a.id, b.title, b.id));
      _setContents(
        path,
        FolderContents(
          notes: notes,
          files: append ? previous.files : results[1] as List<VaultFile>,
          nextCursor: page.nextCursor,
          loaded: true,
        ),
      );
    } catch (e) {
      if (_disposed || _requests[path] != request) return;
      _setContents(
        path,
        FolderContents(
          notes: previous.notes,
          files: previous.files,
          nextCursor: previous.nextCursor,
          loaded: previous.loaded,
          error: e,
        ),
      );
    }
  }

  List<FolderTreeNode> childrenOf(String path) {
    if (path.isEmpty) return value.roots;
    List<FolderTreeNode>? find(List<FolderTreeNode> nodes) {
      for (final node in nodes) {
        if (node.path == path) return node.children;
        final found = find(node.children);
        if (found != null) return found;
      }
      return null;
    }

    return find(value.roots) ?? const [];
  }

  void cancelReveal() {
    ++_revealRequest;
  }

  Future<void> revealNote(String id, String path) async {
    final request = ++_revealRequest;
    await _revealAncestors(path, request);
    if (_disposed || request != _revealRequest) return;
    await expand(path);
    final cursors = <String>{};
    while (!_disposed && request == _revealRequest) {
      final contents = value.contents[path];
      if (contents == null ||
          contents.error != null ||
          contents.notes.any((n) => n.id == id)) {
        return;
      }
      final cursor = contents.nextCursor;
      if (cursor == null || !cursors.add(cursor)) return;
      await loadMore(path);
    }
  }

  Future<void> revealFile(String path) =>
      _revealAncestors(path, ++_revealRequest);
  Future<void> _revealAncestors(String path, int request) async {
    final parts = path.split('/');
    var current = '';
    for (final part in parts) {
      if (_disposed || request != _revealRequest) return;
      current = current.isEmpty ? part : '$current/$part';
      await expand(current);
    }
  }

  void _onEvent(RealtimeEvent event) {
    if (event is! RealtimeMessage || event.message is! ChangedEvent) return;
    final msg = event.message as ChangedEvent;
    if (msg.action == ChangeAction.updated) {
      for (final path in value.contents.keys.toList()) {
        unawaited(loadFolder(path, force: true));
      }
    } else {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_revealRequest;
    _sub?.cancel();
    super.dispose();
  }
}
