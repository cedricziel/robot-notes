import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../widgets/adaptive.dart';
import '../knowledge/knowledge_proposals_screen.dart';
import 'folder_tree_controller.dart';

class FolderTreeSidebar extends StatefulWidget {
  const FolderTreeSidebar({
    required this.controller,
    required this.onSelect,
    required this.onCreateFolder,
    this.selectedPath,
    this.selectedNoteId,
    this.selectedFilePath,
    this.onSelectNote,
    this.onSelectFile,
    this.databases,
    this.onSelectDatabase,
    this.onNewDatabase,
    this.documentOpen = false,
    super.key,
  });
  final FolderTreeController controller;
  final ValueChanged<String?> onSelect;
  final VoidCallback onCreateFolder;
  final String? selectedPath;
  final String? selectedNoteId;
  final String? selectedFilePath;
  final ValueChanged<String>? onSelectNote;
  final ValueChanged<VaultFile>? onSelectFile;
  final List<DatabaseSummary>? databases;
  final ValueChanged<String>? onSelectDatabase;
  final VoidCallback? onNewDatabase;
  final bool documentOpen;
  @override
  State<FolderTreeSidebar> createState() => _FolderTreeSidebarState();
}

class _FolderTreeSidebarState extends State<FolderTreeSidebar> {
  final Map<String, GlobalKey> _rowKeys = {};
  final ScrollController _scroll = ScrollController();
  String? _revealed;
  int _treeRowIndex = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.controller.value.roots.isEmpty) {
        unawaited(widget.controller.refresh(refreshContents: false));
      }
      unawaited(widget.controller.loadFolder(''));
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _row(TreeEntry entry) {
    final index = _treeRowIndex++;
    final selected = entry.selected;
    final rowKey = _rowKeys.putIfAbsent(entry.id, () => GlobalKey());
    if (selected && _revealed != entry.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (rowKey.currentContext == null && _scroll.hasClients) {
          _scroll.jumpTo(
            ((index + 2) * 42.0).clamp(0, _scroll.position.maxScrollExtent),
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && rowKey.currentContext != null) {
              _revealed = entry.id;
              unawaited(
                Scrollable.ensureVisible(rowKey.currentContext!, alignment: .4),
              );
            }
          });
        } else if (rowKey.currentContext != null) {
          _revealed = entry.id;
          unawaited(
            Scrollable.ensureVisible(rowKey.currentContext!, alignment: .4),
          );
        }
      });
    }
    return KeyedSubtree(
      key: rowKey,
      child: VaultTreeRow(entry: entry),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<FolderTreeState>(
    valueListenable: widget.controller,
    builder: (context, state, _) {
      if (widget.selectedNoteId == null && widget.selectedFilePath == null) {
        _revealed = null;
      }
      _treeRowIndex = 0;
      final rows = <Widget>[];
      void addContents(String path, int depth) {
        for (final entry in documentEntries(
          widget.controller,
          path,
          depth,
          selectedNoteId: widget.selectedNoteId,
          selectedFilePath: widget.selectedFilePath,
          onSelectNote: widget.onSelectNote,
          onSelectFile: widget.onSelectFile,
        )) {
          rows.add(_row(entry));
        }
      }

      void addFolder(FolderTreeNode node, int depth) {
        final expanded = state.expandedPaths.contains(node.path);
        rows.add(
          _row(
            TreeEntry(
              id: 'folder.${node.path}',
              title: node.name,
              icon: useCupertino(context)
                  ? CupertinoIcons.folder
                  : Icons.folder_outlined,
              depth: depth,
              count: node.noteCount,
              expanded: expanded,
              selected:
                  !widget.documentOpen && widget.selectedPath == node.path,
              onActivate: () => widget.onSelect(node.path),
              onExpand: () => unawaited(widget.controller.expand(node.path)),
              onCollapse: () => widget.controller.collapse(node.path),
              onToggle: () => unawaited(widget.controller.toggle(node.path)),
            ),
          ),
        );
        if (expanded) {
          for (final child in node.children) {
            addFolder(child, depth + 1);
          }
          addContents(node.path, depth + 1);
        }
      }

      for (final node in state.roots) {
        addFolder(node, 0);
      }
      addContents('', 0);
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 10, 8),
              child: Row(
                children: [
                  const Expanded(child: Text('Vault')),
                  IconButton(
                    key: const Key('sidebar.refresh'),
                    tooltip: 'Refresh vault',
                    icon: const Icon(Icons.refresh, size: 19),
                    onPressed: () => unawaited(widget.controller.refresh()),
                  ),
                  IconButton(
                    key: const Key('sidebar.newFolder'),
                    tooltip: 'New folder',
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 19,
                    ),
                    onPressed: widget.onCreateFolder,
                  ),
                ],
              ),
            ),
            Expanded(
              child: FocusTraversalGroup(
                child: ListView(
                  key: const Key('sidebar.tree'),
                  controller: _scroll,
                  children: [
                    _row(
                      TreeEntry(
                        id: 'allNotes',
                        title: 'All notes',
                        icon: Icons.description_outlined,
                        selected:
                            !widget.documentOpen && widget.selectedPath == null,
                        onActivate: () => widget.onSelect(null),
                      ),
                    ),
                    _row(
                      TreeEntry(
                        id: 'root',
                        title: 'Vault root',
                        icon: Icons.folder_open_outlined,
                        count: state.rootNoteCount,
                        selected:
                            !widget.documentOpen && widget.selectedPath == '',
                        onActivate: () => widget.onSelect(''),
                      ),
                    ),
                    if (state.isLoading) const LinearProgressIndicator(),
                    if (state.error != null)
                      TextButton(
                        onPressed: () => unawaited(widget.controller.refresh()),
                        child: const Text('Could not load vault. Retry'),
                      ),
                    ...rows,
                    const Divider(),
                    _row(
                      TreeEntry(
                        id: 'proposals',
                        title: 'Knowledge proposals',
                        icon: Icons.fact_check_outlined,
                        onActivate: () {
                          Scaffold.maybeOf(context)?.closeDrawer();
                          Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => KnowledgeProposalsScreen(
                                api: widget.controller.api,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (widget.databases != null) ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 20, right: 10),
                        child: Row(
                          children: [
                            const Expanded(child: Text('Databases')),
                            if (widget.onNewDatabase != null)
                              IconButton(
                                key: const Key('sidebar.newDatabase'),
                                tooltip: 'New database',
                                icon: const Icon(Icons.add, size: 19),
                                onPressed: widget.onNewDatabase,
                              ),
                          ],
                        ),
                      ),
                      for (final db in widget.databases!)
                        _row(
                          TreeEntry(
                            id: 'database.${db.id}',
                            title: db.title,
                            icon: Icons.table_chart_outlined,
                            onActivate: widget.onSelectDatabase == null
                                ? null
                                : () => widget.onSelectDatabase!(db.id),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class TreeEntry {
  const TreeEntry({
    required this.id,
    required this.title,
    required this.icon,
    this.depth = 0,
    this.count,
    this.selected = false,
    this.expanded,
    this.onActivate,
    this.onToggle,
    this.onExpand,
    this.onCollapse,
  });
  final String id;
  final String title;
  final IconData icon;
  final int depth;
  final int? count;
  final bool selected;
  final bool? expanded;
  final VoidCallback? onActivate;
  final VoidCallback? onToggle;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;
}

List<TreeEntry> documentEntries(
  FolderTreeController controller,
  String path,
  int depth, {
  String? selectedNoteId,
  String? selectedFilePath,
  ValueChanged<String>? onSelectNote,
  ValueChanged<VaultFile>? onSelectFile,
}) {
  final contents = controller.value.contents[path];
  if (contents == null) return const [];
  final entries = <TreeEntry>[
    for (final note in contents.notes)
      TreeEntry(
        id: 'note.${note.id}',
        title: note.title,
        icon: Icons.description_outlined,
        depth: depth,
        selected: selectedNoteId == note.id,
        onActivate: onSelectNote == null ? null : () => onSelectNote(note.id),
      ),
    for (final file in contents.files)
      TreeEntry(
        id: 'file.${file.relativePath}',
        title: file.filename,
        icon: Icons.insert_drive_file_outlined,
        depth: depth,
        selected: selectedFilePath == file.relativePath,
        onActivate: onSelectFile == null ? null : () => onSelectFile(file),
      ),
  ]..sort((a, b) => compareTreeLabels(a.title, a.id, b.title, b.id));
  if (contents.isLoading) {
    entries.add(
      TreeEntry(
        id: 'loading.$path',
        title: 'Loading…',
        icon: Icons.hourglass_empty,
        depth: depth,
      ),
    );
  }
  if (contents.error != null) {
    entries.add(
      TreeEntry(
        id: 'retry.$path',
        title: 'Could not load contents. Retry',
        icon: Icons.refresh,
        depth: depth,
        onActivate: () => unawaited(controller.loadFolder(path, force: true)),
      ),
    );
  }
  if (contents.nextCursor != null && !contents.isLoading) {
    entries.add(
      TreeEntry(
        id: 'more.$path',
        title: 'Load more',
        icon: Icons.more_horiz,
        depth: depth,
        onActivate: () => unawaited(controller.loadMore(path)),
      ),
    );
  }
  return entries;
}

class VaultTreeRow extends StatefulWidget {
  const VaultTreeRow({required this.entry, super.key});
  final TreeEntry entry;
  @override
  State<VaultTreeRow> createState() => _VaultTreeRowState();
}

class _VaultTreeRowState extends State<VaultTreeRow> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      descendantsAreTraversable: false,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowDown) {
          node.nextFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          node.previousFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight && entry.onExpand != null) {
          entry.onExpand!();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft && entry.onCollapse != null) {
          entry.onCollapse!();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          entry.onActivate?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        selected: entry.selected,
        expanded: entry.expanded,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Material(
            color: entry.selected
                ? scheme.primaryContainer
                : _focused
                ? scheme.surfaceContainerHighest
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: 40,
              child: ListTile(
                key: Key('sidebar.${entry.id}'),
                dense: true,
                minTileHeight: 40,
                visualDensity: const VisualDensity(vertical: -2),
                contentPadding: EdgeInsets.only(
                  left: 8 + entry.depth * 14.0,
                  right: 8,
                ),
                minLeadingWidth: 18,
                horizontalTitleGap: 8,
                selected: entry.selected,
                selectedColor: scheme.onPrimaryContainer,
                leading: Icon(entry.icon, size: 18),
                title: Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: entry.selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (entry.count != null && entry.count! > 0)
                      Text(
                        '${entry.count}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    if (entry.expanded != null)
                      ExcludeFocus(
                        child: IconButton(
                          key: Key('sidebar.expand.${entry.id.substring(7)}'),
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: entry.expanded!
                              ? 'Collapse ${entry.title}'
                              : 'Expand ${entry.title}',
                          icon: Icon(
                            entry.expanded!
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 18,
                          ),
                          onPressed: entry.onToggle,
                        ),
                      ),
                  ],
                ),
                onTap: entry.onActivate,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
