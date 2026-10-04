import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

/// An explicit row source. An unfinished folder or tag reports null so
/// callers can prevent saving an accidentally vault-wide definition.
class DatabaseSourceEditor extends StatefulWidget {
  const DatabaseSourceEditor({
    required this.onChanged,
    this.initialSource,
    super.key,
  });

  final DatabaseSource? initialSource;
  final ValueChanged<DatabaseSource?> onChanged;

  @override
  State<DatabaseSourceEditor> createState() => _DatabaseSourceEditorState();
}

enum _SourceKind { folder, tag, root }

class _DatabaseSourceEditorState extends State<DatabaseSourceEditor> {
  late _SourceKind _kind = widget.initialSource?.tag != null
      ? _SourceKind.tag
      : widget.initialSource?.folder == ''
      ? _SourceKind.root
      : _SourceKind.folder;
  late final _folder = TextEditingController(
    text: widget.initialSource?.folder,
  );
  late final _tag = TextEditingController(text: widget.initialSource?.tag);
  late bool _includeSubfolders =
      widget.initialSource?.includeSubfolders ?? true;

  void _changed() {
    setState(() {});
    final text = (_kind == _SourceKind.tag ? _tag : _folder).text.trim();
    widget.onChanged(switch (_kind) {
      _SourceKind.root => DatabaseSource.folder(
        '',
        includeSubfolders: _includeSubfolders,
      ),
      _SourceKind.folder =>
        text.isEmpty
            ? null
            : DatabaseSource.folder(
                text,
                includeSubfolders: _includeSubfolders,
              ),
      _SourceKind.tag => text.isEmpty ? null : DatabaseSource.tag(text),
    });
  }

  @override
  void dispose() {
    _folder.dispose();
    _tag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Rows from', style: Theme.of(context).textTheme.titleMedium),
      DropdownButton<_SourceKind>(
        key: const Key('databaseSource.kind'),
        value: _kind,
        items: const [
          DropdownMenuItem(value: _SourceKind.folder, child: Text('Folder')),
          DropdownMenuItem(value: _SourceKind.tag, child: Text('Tag')),
          DropdownMenuItem(value: _SourceKind.root, child: Text('Vault root')),
        ],
        onChanged: (kind) {
          if (kind == null) return;
          _kind = kind;
          _changed();
        },
      ),
      if (_kind == _SourceKind.folder)
        TextFormField(
          key: const Key('databaseSource.folder'),
          controller: _folder,
          decoration: const InputDecoration(
            labelText: 'Folder',
            helperText: 'Choose the folder whose notes become rows.',
          ),
          onChanged: (_) => _changed(),
        ),
      if (_kind == _SourceKind.tag)
        TextFormField(
          key: const Key('databaseSource.tag'),
          controller: _tag,
          decoration: const InputDecoration(
            labelText: 'Tag',
            helperText: 'Matches notes with this tag in any folder.',
          ),
          onChanged: (_) => _changed(),
        ),
      if (_kind != _SourceKind.tag)
        SwitchListTile(
          key: const Key('databaseSource.includeSubfolders'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Include subfolders'),
          subtitle: _kind == _SourceKind.root
              ? Text(
                  _includeSubfolders
                      ? 'Includes notes throughout the vault.'
                      : 'Only notes directly in the vault root.',
                )
              : null,
          value: _includeSubfolders,
          onChanged: (value) {
            _includeSubfolders = value;
            _changed();
          },
        ),
    ],
  );
}
