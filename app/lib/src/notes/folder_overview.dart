import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import 'folder_tree_controller.dart';
import 'folder_tree_sidebar.dart';

class FolderOverview extends StatefulWidget {
  const FolderOverview({
    required this.controller,
    required this.path,
    required this.onSelectFolder,
    required this.onSelectNote,
    required this.onSelectFile,
    required this.onCreateNote,
    required this.onCreateFolder,
    required this.onUploadFile,
    this.sidebar,
    super.key,
  });
  final FolderTreeController controller;
  final String path;
  final ValueChanged<String?> onSelectFolder;
  final ValueChanged<String> onSelectNote;
  final ValueChanged<VaultFile> onSelectFile;
  final VoidCallback onCreateNote;
  final VoidCallback onCreateFolder;
  final VoidCallback onUploadFile;
  final Widget? sidebar;
  @override
  State<FolderOverview> createState() => _FolderOverviewState();
}

class _FolderOverviewState extends State<FolderOverview> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FolderOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _load();
  }

  void _load() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tree = widget.controller;
      if (tree.value.roots.isEmpty && !tree.value.isLoading) {
        unawaited(tree.refresh(refreshContents: false));
      }
      unawaited(tree.loadFolder(widget.path));
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.path.isEmpty ? 'Vault root' : widget.path.split('/').last,
      ),
      actions: [
        IconButton(
          tooltip: 'New note',
          icon: const Icon(Icons.note_add_outlined),
          onPressed: widget.onCreateNote,
        ),
        IconButton(
          tooltip: 'New folder',
          icon: const Icon(Icons.create_new_folder_outlined),
          onPressed: widget.onCreateFolder,
        ),
        IconButton(
          tooltip: 'Upload file',
          icon: const Icon(Icons.upload_file_outlined),
          onPressed: widget.onUploadFile,
        ),
      ],
    ),
    drawer: widget.sidebar == null ? null : Drawer(child: widget.sidebar),
    body: ValueListenableBuilder<FolderTreeState>(
      valueListenable: widget.controller,
      builder: (context, state, _) {
        final folders = widget.controller.childrenOf(widget.path);
        final entries = documentEntries(
          widget.controller,
          widget.path,
          0,
          onSelectNote: widget.onSelectNote,
          onSelectFile: widget.onSelectFile,
        );
        final parts = widget.path.isEmpty ? <String>[] : widget.path.split('/');
        return ListView(
          key: PageStorageKey('overview.${widget.path}'),
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  key: const Key('overview.allNotes'),
                  onPressed: () => widget.onSelectFolder(null),
                  child: const Text('All notes'),
                ),
                const Icon(Icons.chevron_right, size: 16),
                TextButton(
                  key: const Key('overview.root'),
                  onPressed: () => widget.onSelectFolder(''),
                  child: const Text('Vault root'),
                ),
                for (var i = 0; i < parts.length; i++) ...[
                  const Icon(Icons.chevron_right, size: 16),
                  TextButton(
                    key: Key('overview.breadcrumb.$i'),
                    onPressed: () =>
                        widget.onSelectFolder(parts.take(i + 1).join('/')),
                    child: Text(parts[i]),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            for (final folder in folders)
              VaultTreeRow(
                entry: TreeEntry(
                  id: 'overview.folder.${folder.path}',
                  title: folder.name,
                  icon: Icons.folder_outlined,
                  onActivate: () => widget.onSelectFolder(folder.path),
                ),
              ),
            for (final entry in entries) VaultTreeRow(entry: entry),
            if (!state.isLoading &&
                folders.isEmpty &&
                entries.isEmpty &&
                state.contents[widget.path]?.loaded == true)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('This folder is empty.'),
              ),
          ],
        );
      },
    ),
  );
}
