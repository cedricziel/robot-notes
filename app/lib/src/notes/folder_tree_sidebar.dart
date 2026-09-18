import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'folder_tree_controller.dart';

/// Sidebar (or drawer, on narrow screens) presenting the vault as an
/// expandable folder tree, backed by [FolderTreeController]. An "All
/// notes" entry always sits at the top and clears the folder scope;
/// selecting any other entry calls [onSelect] with that folder's full path.
///
/// Optionally also shows a "Databases" section — task 6.1's sidebar entry
/// point for creating a database, ahead of task 7.3's full sidebar list —
/// when [databases] is given: every entry by title plus a "New database"
/// header action, matching the `flutter-client` spec's "Sidebar lists
/// databases and can create one" requirement.
class FolderTreeSidebar extends StatefulWidget {
  const FolderTreeSidebar({
    required this.controller,
    required this.onSelect,
    required this.onCreateFolder,
    this.selectedPath,
    this.databases,
    this.onSelectDatabase,
    this.onNewDatabase,
    super.key,
  });

  final FolderTreeController controller;
  final ValueChanged<String?> onSelect;

  /// Invoked when the user taps the "New folder" header action.
  final VoidCallback onCreateFolder;

  /// The folder currently scoping the notes list, or `null` for "All
  /// notes" — used only to highlight the active selection.
  final String? selectedPath;

  /// The Databases section's entries. `null` hides the section entirely.
  final List<DatabaseSummary>? databases;

  /// Called with a database's id when the user taps its entry.
  final ValueChanged<String>? onSelectDatabase;

  /// Invoked when the user taps the "New database" header action.
  final VoidCallback? onNewDatabase;

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
                  Expanded(
                    child: Text(
                      'Folders',
                      style: Theme.of(context).textTheme.titleSmall,
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
                    shape: _selectedShape,
                    leading: const Icon(Icons.all_inbox),
                    title: const Text('All notes'),
                    selected: widget.selectedPath == null,
                    onTap: () => widget.onSelect(null),
                  ),
                  if (state.rootNoteCount != null)
                    ListTile(
                      key: const Key('sidebar.root'),
                      shape: _selectedShape,
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
                  if (widget.databases != null) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Databases',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          if (widget.onNewDatabase != null)
                            IconButton(
                              key: const Key('sidebar.newDatabase'),
                              tooltip: 'New database',
                              icon: const Icon(Icons.add_box_outlined),
                              onPressed: widget.onNewDatabase,
                            ),
                        ],
                      ),
                    ),
                    for (final db in widget.databases!)
                      ListTile(
                        key: Key('sidebar.database.${db.id}'),
                        shape: _selectedShape,
                        leading: const Icon(Icons.table_chart_outlined),
                        title: Text(db.title),
                        onTap: widget.onSelectDatabase == null
                            ? null
                            : () => widget.onSelectDatabase!(db.id),
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Rounds the trailing edge of a highlighted tile the way a
/// [NavigationDrawer] does, so the selection reads as a pill against the
/// panel's straight leading edge.
const ShapeBorder _selectedShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
);

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
        shape: _selectedShape,
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
          shape: _selectedShape,
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
