import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../widgets/error_strip.dart';

/// Shows a "New folder" prompt and, on confirm, calls
/// `POST /notes/tree` via [api]. Returns `true` if a folder was created,
/// `false` if the user cancelled. On failure the dialog stays open and
/// shows the server's error message rather than dismissing destructively
/// — the caller only needs to decide what to do once this resolves
/// (typically: re-fetch the folder tree).
Future<bool> showCreateFolderDialog(
  BuildContext context, {
  required RobotNotesClient api,
  String? initialPath,
}) async {
  final created = await showDialog<bool>(
    context: context,
    builder: (_) => _CreateFolderDialog(api: api, initialPath: initialPath),
  );
  return created ?? false;
}

class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog({required this.api, this.initialPath});

  final RobotNotesClient api;
  final String? initialPath;

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  late String _draft = widget.initialPath ?? '';
  String? _error;
  bool _submitting = false;

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.api.createFolder(_draft);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = describeError(e, fallback: 'Could not create folder.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New folder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            key: const Key('folder.create.input'),
            initialValue: _draft,
            autofocus: true,
            enabled: !_submitting,
            onChanged: (v) => _draft = v,
            decoration: const InputDecoration(
              labelText: 'Folder path',
              hintText: 'e.g. Projects/Alpha',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              key: const Key('folder.create.error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('folder.create.cancel'),
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('folder.create.confirm'),
          onPressed: _submitting ? null : _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
