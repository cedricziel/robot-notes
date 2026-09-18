import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../widgets/adaptive.dart';

/// The commit signature every cell/card editor in the database screen uses:
/// the property key being edited, and the patch to send for it.
///
/// This is deliberately the same shape `DatabaseController.patchProperty`
/// takes (`set`/`unset`), so a caller only has to fan it out to
/// `controller.patchProperty(rowId, set: patch.set, unset: patch.unset)`.
typedef PropertyPatchCommit =
    void Function(String propertyKey, PropertyPatch patch);

/// Placeholder inline cell editor used by the table (task 5.2) and the
/// board card (task 5.4) until group 4's typed `PropertyEditor` widget
/// family lands. Renders the value as plain text and, on tap, opens a
/// single free-text field that commits a `{set: {key: text}}` patch, or
/// `{unset: [key]}` when cleared to empty.
///
/// This is intentionally the *only* place group 5's screens talk to a
/// property value's editing UI, so swapping it for the real
/// `PropertyEditor(type, value, onCommit)` from design.md is a one-widget
/// change once task 4.1 merges — see the follow-up note on task 5.2 in
/// `openspec/changes/add-database-views/tasks.md`.
class DatabaseCellEditor extends StatelessWidget {
  const DatabaseCellEditor({
    required this.propertyKey,
    required this.value,
    required this.onCommit,
    this.enabled = true,
    super.key,
  });

  final String propertyKey;
  final Object? value;
  final PropertyPatchCommit onCommit;
  final bool enabled;

  String get _display {
    if (value == null) return '';
    if (value is List) return (value! as List).join(', ');
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final text = _display;
    return InkWell(
      key: Key('cell.$propertyKey.tap'),
      onTap: enabled ? () => _openEditor(context) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(
          text.isEmpty ? '—' : text,
          overflow: TextOverflow.ellipsis,
          style: text.isEmpty
              ? TextStyle(color: Theme.of(context).colorScheme.outline)
              : null,
        ),
      ),
    );
  }

  Future<void> _openEditor(BuildContext context) async {
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) =>
          _CellEditorDialog(propertyKey: propertyKey, initial: _display),
    );
    // `null` means cancelled; an empty string means the user cleared it.
    if (result == null) return;
    if (result.isEmpty) {
      onCommit(propertyKey, PropertyPatch(unset: [propertyKey]));
    } else {
      onCommit(propertyKey, PropertyPatch(set: {propertyKey: result}));
    }
  }
}

class _CellEditorDialog extends StatefulWidget {
  const _CellEditorDialog({required this.propertyKey, required this.initial});

  final String propertyKey;
  final String initial;

  @override
  State<_CellEditorDialog> createState() => _CellEditorDialogState();
}

class _CellEditorDialogState extends State<_CellEditorDialog> {
  late String _draft = widget.initial;

  @override
  Widget build(BuildContext context) {
    return AlertDialog.adaptive(
      title: Text('Edit ${widget.propertyKey}'),
      content: AdaptiveDialogTextField(
        key: const Key('cell.editor.input'),
        initialValue: _draft,
        label: widget.propertyKey,
        hint: '',
        onChanged: (v) => _draft = v,
      ),
      actions: [
        adaptiveDialogAction(
          context,
          key: const Key('cell.editor.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        adaptiveDialogAction(
          context,
          key: const Key('cell.editor.clear'),
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('Clear'),
        ),
        adaptiveDialogAction(
          context,
          key: const Key('cell.editor.save'),
          primary: true,
          onPressed: () => Navigator.of(context).pop(_draft),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
