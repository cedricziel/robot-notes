import 'package:flutter/material.dart';
import '../api/api_client.dart';

/// Vault picker and management actions shared across the app's screens.
class VaultSwitcher extends StatefulWidget {
  const VaultSwitcher({
    required this.api,
    required this.selectedId,
    required this.onSelect,
    required this.canManage,
    super.key,
  });
  final RobotNotesClient api;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final bool canManage;
  @override
  State<VaultSwitcher> createState() => _VaultSwitcherState();
}

class _VaultSwitcherState extends State<VaultSwitcher> {
  List<Map<String, String>> _vaults = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final vaults = await widget.api.listVaults();
      if (mounted) {
        setState(() {
          _vaults = vaults;
          _error = null;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Could not load vaults: $e');
    }
  }

  Future<void> _name({bool rename = false}) async {
    final current = _vaults
        .where((v) => v['id'] == widget.selectedId)
        .firstOrNull;
    var enteredName = rename && current != null ? current['name']! : '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(rename ? 'Rename vault' : 'Create vault'),
        content: TextFormField(
          initialValue: enteredName,
          onChanged: (value) => enteredName = value,
          autofocus: true,
          maxLength: 200,
          decoration: const InputDecoration(labelText: 'Vault name'),
          onFieldSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (enteredName.trim().isNotEmpty) {
                Navigator.pop(context, enteredName.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || name == null) return;
    try {
      if (rename) {
        await widget.api.renameVault(widget.selectedId, name);
        await _load();
      } else {
        final vault = await widget.api.createVault(name);
        if (mounted) widget.onSelect(vault['id']!);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Could not save vault: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined, size: 20),
            const SizedBox(width: 8),
            if (_vaults.isNotEmpty)
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _vaults.any((v) => v['id'] == widget.selectedId)
                      ? widget.selectedId
                      : null,
                  hint: const Text('Select vault'),
                  items: [
                    for (final v in _vaults)
                      DropdownMenuItem(value: v['id'], child: Text(v['name']!)),
                  ],
                  onChanged: (id) {
                    if (id != null && id != widget.selectedId) {
                      widget.onSelect(id);
                    }
                  },
                ),
              )
            else
              const Expanded(child: Text('Vaults')),
            if (_error != null)
              Tooltip(
                message: _error!,
                child: IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                ),
              ),
            if (widget.canManage && widget.api.canManageVaults) ...[
              IconButton(
                tooltip: 'Create vault',
                onPressed: _name,
                icon: const Icon(Icons.add),
              ),
              IconButton(
                tooltip: 'Rename vault',
                onPressed: () => _name(rename: true),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
