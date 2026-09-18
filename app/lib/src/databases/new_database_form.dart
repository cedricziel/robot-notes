import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import 'schema_editor_screen.dart' show propertyKeyPattern;

/// A full-screen "New database" form, per the `flutter-client` spec's
/// "Sidebar lists databases and can create one" requirement (task 6.1):
/// title, a folder-or-tag source, an initial property list, and a first
/// view. Submitting calls `POST /databases`; a 400 `validation_failed`
/// keeps the form open with the server's message shown inline.
class NewDatabaseForm extends StatefulWidget {
  const NewDatabaseForm({
    required this.api,
    required this.onCreated,
    this.onClose,
    this.initialFolder,
    super.key,
  });

  final RobotNotesClient api;
  final ValueChanged<DatabaseDefinition> onCreated;
  final VoidCallback? onClose;

  /// Pre-fills the folder source field, e.g. from the currently selected
  /// sidebar folder.
  final String? initialFolder;

  @override
  State<NewDatabaseForm> createState() => _NewDatabaseFormState();
}

enum _SourceKind { folder, tag }

class _NewDatabaseFormState extends State<NewDatabaseForm> {
  final _titleController = TextEditingController();
  late final _folderController = TextEditingController(
    text: widget.initialFolder ?? '',
  );
  final _tagController = TextEditingController();
  final _pathController = TextEditingController();
  _SourceKind _sourceKind = _SourceKind.folder;

  final List<_NewPropertyRow> _properties = [_NewPropertyRow()];
  final _viewNameController = TextEditingController(text: 'All');
  ViewType _viewType = ViewType.table;
  final _viewGroupByController = TextEditingController();

  bool _submitting = false;
  String? _error;
  int _rowSeq = 1;

  bool get _keysValid {
    final seen = <String>{};
    for (final p in _properties) {
      final key = p.keyController.text.trim();
      if (key.isEmpty) continue;
      if (!propertyKeyPattern.hasMatch(key)) return false;
      if (!seen.add(key)) return false;
    }
    return true;
  }

  bool get _canSubmit =>
      !_submitting &&
      _titleController.text.trim().isNotEmpty &&
      _keysValid &&
      _viewNameController.text.trim().isNotEmpty;

  void _addProperty() {
    setState(() => _properties.add(_NewPropertyRow(id: _rowSeq++)));
  }

  void _removeProperty(_NewPropertyRow row) {
    setState(() => _properties.remove(row));
  }

  DatabaseSource? _buildSource() {
    if (_sourceKind == _SourceKind.tag) {
      final tag = _tagController.text.trim();
      return tag.isEmpty ? null : DatabaseSource.tag(tag);
    }
    final folder = _folderController.text.trim();
    return folder.isEmpty ? null : DatabaseSource.folder(folder);
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final properties = <String, PropertyDefinition>{
        for (final p in _properties)
          if (p.keyController.text.trim().isNotEmpty)
            p.keyController.text.trim(): p.toDefinition(),
      };
      final view = ViewDefinition(
        name: _viewNameController.text.trim(),
        type: _viewType,
        groupBy:
            _viewType == ViewType.board &&
                _viewGroupByController.text.trim().isNotEmpty
            ? _viewGroupByController.text.trim()
            : null,
      );
      final path = _pathController.text.trim();
      final definition = await widget.api.createDatabase(
        title: _titleController.text.trim(),
        path: path.isEmpty ? null : path,
        source: _buildSource(),
        properties: properties,
        views: [view],
      );
      if (!mounted) return;
      widget.onCreated(definition);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not create this database.';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New database'),
        leading: IconButton(
          key: const Key('newDatabase.close'),
          icon: const Icon(Icons.close),
          onPressed: _close,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton(
              key: const Key('newDatabase.submit'),
              onPressed: _canSubmit ? _submit : null,
              child: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Container(
              key: const Key('newDatabase.error'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!),
            ),
          TextFormField(
            key: const Key('newDatabase.title'),
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Title'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('newDatabase.path'),
            controller: _pathController,
            decoration: const InputDecoration(
              labelText: 'Definition note location (optional)',
              hintText: 'Defaults to the source folder, or the vault root',
            ),
          ),
          const SizedBox(height: 16),
          Text('Source', style: Theme.of(context).textTheme.titleSmall),
          RadioGroup<_SourceKind>(
            groupValue: _sourceKind,
            onChanged: (v) {
              if (v != null) setState(() => _sourceKind = v);
            },
            child: Row(
              children: [
                Expanded(
                  child: RadioListTile<_SourceKind>(
                    key: const Key('newDatabase.source.folder'),
                    title: const Text('Folder'),
                    value: _SourceKind.folder,
                  ),
                ),
                Expanded(
                  child: RadioListTile<_SourceKind>(
                    key: const Key('newDatabase.source.tag'),
                    title: const Text('Tag'),
                    value: _SourceKind.tag,
                  ),
                ),
              ],
            ),
          ),
          if (_sourceKind == _SourceKind.folder)
            TextFormField(
              key: const Key('newDatabase.folder'),
              controller: _folderController,
              decoration: const InputDecoration(labelText: 'Folder'),
            )
          else
            TextFormField(
              key: const Key('newDatabase.tag'),
              controller: _tagController,
              decoration: const InputDecoration(labelText: 'Tag'),
            ),
          const Divider(height: 32),
          Text('Properties', style: Theme.of(context).textTheme.titleSmall),
          for (final row in _properties)
            _NewPropertyEditorRow(
              key: ValueKey<int>(row.id),
              row: row,
              onChanged: () => setState(() {}),
              onRemove: _properties.length > 1
                  ? () => _removeProperty(row)
                  : null,
            ),
          TextButton.icon(
            key: const Key('newDatabase.addProperty'),
            onPressed: _addProperty,
            icon: const Icon(Icons.add),
            label: const Text('Add property'),
          ),
          const Divider(height: 32),
          Text('First view', style: Theme.of(context).textTheme.titleSmall),
          TextFormField(
            key: const Key('newDatabase.view.name'),
            controller: _viewNameController,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          DropdownButton<ViewType>(
            key: const Key('newDatabase.view.type'),
            value: _viewType,
            items: [
              for (final t in ViewType.values)
                DropdownMenuItem(value: t, child: Text(t.wire)),
            ],
            onChanged: (t) {
              if (t != null) setState(() => _viewType = t);
            },
          ),
          if (_viewType == ViewType.board)
            TextFormField(
              key: const Key('newDatabase.view.groupBy'),
              controller: _viewGroupByController,
              decoration: const InputDecoration(labelText: 'Group by'),
            ),
        ],
      ),
    );
  }
}

class _NewPropertyRow {
  _NewPropertyRow({int? id}) : id = id ?? 0;

  final int id;
  final keyController = TextEditingController();
  final labelController = TextEditingController();
  final optionsController = TextEditingController();
  PropertyType type = PropertyType.text;

  bool get needsOptions =>
      type == PropertyType.select || type == PropertyType.multiSelect;

  PropertyDefinition toDefinition() => PropertyDefinition(
    type: type,
    label: labelController.text.trim().isEmpty
        ? null
        : labelController.text.trim(),
    options: needsOptions
        ? optionsController.text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList()
        : null,
  );
}

class _NewPropertyEditorRow extends StatelessWidget {
  const _NewPropertyEditorRow({
    required this.row,
    required this.onChanged,
    this.onRemove,
    super.key,
  });

  final _NewPropertyRow row;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final key = row.keyController.text.trim();
    final keyValid = key.isEmpty || propertyKeyPattern.hasMatch(key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: Key('newDatabase.property.${row.id}.key'),
                  controller: row.keyController,
                  decoration: InputDecoration(
                    labelText: 'Key',
                    errorText: keyValid
                        ? null
                        : 'Must match ^[a-z][a-z0-9_]*\$',
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<PropertyType>(
                key: Key('newDatabase.property.${row.id}.type'),
                value: row.type,
                items: [
                  for (final t in PropertyType.values)
                    DropdownMenuItem(value: t, child: Text(t.wire)),
                ],
                onChanged: (t) {
                  if (t != null) row.type = t;
                  onChanged();
                },
              ),
              if (onRemove != null)
                IconButton(
                  key: Key('newDatabase.property.${row.id}.remove'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onRemove,
                ),
            ],
          ),
          if (row.needsOptions)
            TextFormField(
              key: Key('newDatabase.property.${row.id}.options'),
              controller: row.optionsController,
              decoration: const InputDecoration(
                labelText: 'Options (comma-separated)',
              ),
              onChanged: (_) => onChanged(),
            ),
        ],
      ),
    );
  }
}
