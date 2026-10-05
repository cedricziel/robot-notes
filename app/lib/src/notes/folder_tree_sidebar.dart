import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:shared/shared.dart';

import '../widgets/adaptive.dart';
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
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 10, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Folders', style: _sectionStyle(context)),
                    ),
                    IconButton(
                      key: const Key('sidebar.newFolder'),
                      tooltip: 'New folder',
                      icon: Icon(
                        _sidebarIcon(
                          context,
                          Icons.create_new_folder_outlined,
                          CupertinoIcons.folder_badge_plus,
                        ),
                        size: 19,
                      ),
                      onPressed: widget.onCreateFolder,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  key: const Key('sidebar.tree'),
                  children: [
                    _SidebarRow(
                      tileKey: const Key('sidebar.allNotes'),
                      icon: _sidebarIcon(
                        context,
                        Icons.description_outlined,
                        CupertinoIcons.doc_text,
                      ),
                      title: 'All notes',
                      selected: widget.selectedPath == null,
                      onTap: () => widget.onSelect(null),
                    ),
                    if (state.rootNoteCount != null)
                      _SidebarRow(
                        tileKey: const Key('sidebar.root'),
                        icon: _sidebarIcon(
                          context,
                          Icons.folder_outlined,
                          CupertinoIcons.folder,
                        ),
                        title: '(root)',
                        count: state.rootNoteCount,
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
                      const Divider(height: 24, indent: 20, endIndent: 20),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 10, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Databases',
                                style: _sectionStyle(context),
                              ),
                            ),
                            if (widget.onNewDatabase != null)
                              IconButton(
                                key: const Key('sidebar.newDatabase'),
                                tooltip: 'New database',
                                icon: Icon(
                                  _sidebarIcon(
                                    context,
                                    Icons.add_box_outlined,
                                    CupertinoIcons.plus_square,
                                  ),
                                  size: 19,
                                ),
                                onPressed: widget.onNewDatabase,
                              ),
                          ],
                        ),
                      ),
                      for (final db in widget.databases!)
                        _SidebarRow(
                          tileKey: Key('sidebar.database.${db.id}'),
                          icon: _sidebarIcon(
                            context,
                            Icons.table_chart_outlined,
                            CupertinoIcons.table,
                          ),
                          title: db.title,
                          onTap: widget.onSelectDatabase == null
                              ? null
                              : () => widget.onSelectDatabase!(db.id),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

TextStyle? _sectionStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
    );

IconData _sidebarIcon(
  BuildContext context,
  IconData material,
  IconData apple,
) => useCupertino(context) ? apple : material;

const ShapeBorder _selectedShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(8)),
);

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.tileKey,
    required this.title,
    required this.icon,
    required this.onTap,
    this.count,
    this.selected = false,
    this.indent = 0,
  });

  final Key tileKey;
  final String title;
  final IconData icon;
  final VoidCallback? onTap;
  final int? count;
  final bool selected;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: Colors.transparent,
        shape: _selectedShape,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          key: tileKey,
          shape: _selectedShape,
          dense: true,
          visualDensity: const VisualDensity(vertical: -1),
          minLeadingWidth: 20,
          horizontalTitleGap: 10,
          contentPadding: EdgeInsets.only(left: 12 + indent, right: 12),
          selected: selected,
          selectedColor: theme.colorScheme.primary,
          selectedTileColor: theme.colorScheme.primaryContainer,
          iconColor: theme.colorScheme.onSurfaceVariant,
          leading: Icon(icon, size: 19),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          titleTextStyle: theme.textTheme.bodyMedium?.copyWith(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
          trailing: count == null
              ? null
              : Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
          onTap: onTap,
        ),
      ),
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
    final theme = Theme.of(context);
    final folderIcon = _sidebarIcon(
      context,
      Icons.folder_outlined,
      CupertinoIcons.folder,
    );
    if (node.children.isEmpty) {
      return _SidebarRow(
        tileKey: Key('sidebar.folder.${node.path}'),
        icon: folderIcon,
        indent: indent,
        title: node.name,
        count: node.noteCount,
        selected: selectedPath == node.path,
        onTap: () => onSelect(node.path),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: ExpansionTile(
        key: Key('sidebar.folder.${node.path}'),
        dense: true,
        shape: _selectedShape,
        collapsedShape: _selectedShape,
        tilePadding: EdgeInsets.only(left: 12 + indent, right: 12),
        childrenPadding: const EdgeInsets.only(bottom: 2),
        leading: Icon(folderIcon, size: 19),
        iconColor: theme.colorScheme.onSurfaceVariant,
        collapsedIconColor: theme.colorScheme.onSurfaceVariant,
        textColor: theme.colorScheme.onSurface,
        collapsedTextColor: theme.colorScheme.onSurface,
        title: Row(
          children: [
            Expanded(
              child: Text(
                node.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            // Intermediate nodes have no direct notes to count.
            if (node.noteCount > 0)
              Text(
                '${node.noteCount}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
          ],
        ),
        children: [
          _SidebarRow(
            tileKey: Key('sidebar.folder.${node.path}.select'),
            icon: _sidebarIcon(
              context,
              Icons.folder_open_outlined,
              CupertinoIcons.folder_open,
            ),
            indent: 16 + indent,
            title: 'Open this folder',
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
      ),
    );
  }
}
