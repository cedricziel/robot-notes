import 'package:flutter/material.dart';

import 'folder_tree_controller.dart';

/// Sidebar (or drawer, on narrow screens) presenting the vault as an
/// expandable folder tree, backed by [FolderTreeController]. An "All
/// notes" entry always sits at the top and clears the folder scope;
/// selecting any other entry calls [onSelect] with that folder's full path.
class FolderTreeSidebar extends StatefulWidget {
  const FolderTreeSidebar({
    required this.controller,
    required this.onSelect,
    required this.onCreateFolder,
    this.selectedPath,
    super.key,
  });

  final FolderTreeController controller;
  final ValueChanged<String?> onSelect;

  /// Invoked when the user taps the "New folder" header action.
  final VoidCallback onCreateFolder;

  /// The folder currently scoping the notes list, or `null` for "All
  /// notes" — used only to highlight the active selection.
  final String? selectedPath;

  @override
  State<FolderTreeSidebar> createState() => _FolderTreeSidebarState();
}

class _FolderTreeSidebarState extends State<FolderTreeSidebar> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FolderTreeState>(
      valueListenable: widget.controller,
      builder: (context, state, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Folders',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    key: const Key('sidebar.newFolder'),
                    tooltip: 'New folder',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: widget.onCreateFolder,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                key: const Key('sidebar.tree'),
                children: [
                  ListTile(
                    key: const Key('sidebar.allNotes'),
                    leading: const Icon(Icons.all_inbox),
                    title: const Text('All notes'),
                    selected: widget.selectedPath == null,
                    onTap: () => widget.onSelect(null),
                  ),
                  if (state.rootNoteCount != null)
                    ListTile(
                      key: const Key('sidebar.root'),
                      leading: const Icon(Icons.description_outlined),
                      title: const Text('(root)'),
                      trailing: Text('${state.rootNoteCount}'),
                      selected: widget.selectedPath == '',
                      onTap: () => widget.onSelect(''),
                    ),
                  for (final node in state.roots)
                    _FolderTile(
                      node: node,
                      selectedPath: widget.selectedPath,
                      onSelect: widget.onSelect,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.node,
    required this.selectedPath,
    required this.onSelect,
    this.depth = 0,
  });

  final FolderTreeNode node;
  final String? selectedPath;
  final ValueChanged<String?> onSelect;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final indent = 16.0 * depth;
    if (node.children.isEmpty) {
      return ListTile(
        key: Key('sidebar.folder.${node.path}'),
        contentPadding: EdgeInsets.only(left: 16 + indent, right: 16),
        title: Text(node.name),
        trailing: Text('${node.noteCount}'),
        selected: selectedPath == node.path,
        onTap: () => onSelect(node.path),
      );
    }
    return ExpansionTile(
      key: Key('sidebar.folder.${node.path}'),
      tilePadding: EdgeInsets.only(left: 16 + indent, right: 16),
      title: Text(node.name),
      // A purely intermediate folder (no notes of its own, only nested
      // subfolders that do) has nothing meaningful to show as its own
      // count — leave the default expand chevron in place for it.
      trailing: node.noteCount > 0 ? Text('${node.noteCount}') : null,
      children: [
        ListTile(
          key: Key('sidebar.folder.${node.path}.select'),
          contentPadding: EdgeInsets.only(left: 32 + indent, right: 16),
          title: const Text('Open this folder'),
          selected: selectedPath == node.path,
          onTap: () => onSelect(node.path),
        ),
        for (final child in node.children)
          _FolderTile(
            node: child,
            selectedPath: selectedPath,
            onSelect: onSelect,
            depth: depth + 1,
          ),
      ],
    );
  }
}
