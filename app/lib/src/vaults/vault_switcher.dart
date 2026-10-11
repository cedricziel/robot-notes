import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';

import '../widgets/adaptive.dart';
import '../widgets/platform_motion.dart';

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
    final name = await showPlatformDialog<String>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(rename ? 'Rename vault' : 'Create vault'),
        content: useCupertino(context)
            ? Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CupertinoTextFormFieldRow(
                  initialValue: enteredName,
                  placeholder: 'Vault name',
                  padding: EdgeInsets.zero,
                  onChanged: (value) => enteredName = value,
                  autofocus: true,
                  maxLength: 200,
                  onFieldSubmitted: (value) {
                    if (value.trim().isNotEmpty) {
                      Navigator.pop(context, value.trim());
                    }
                  },
                ),
              )
            : TextFormField(
                initialValue: enteredName,
                onChanged: (value) => enteredName = value,
                autofocus: true,
                maxLength: 200,
                decoration: const InputDecoration(labelText: 'Vault name'),
                onFieldSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    Navigator.pop(context, value.trim());
                  }
                },
              ),
        actions: [
          adaptiveDialogAction(
            context,
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          adaptiveDialogAction(
            context,
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apple = useCupertino(context);
    final desktop = switch (theme.platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };
    final current = _vaults
        .where((v) => v['id'] == widget.selectedId)
        .firstOrNull;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        bottom: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          constraints: BoxConstraints(minHeight: desktop ? 40 : 48),
          child: Row(
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: PopupMenuButton<String>(
                    tooltip: 'Switch vault',
                    enabled: _vaults.isNotEmpty,
                    initialValue: current?['id'],
                    onSelected: (id) {
                      if (id != widget.selectedId) widget.onSelect(id);
                    },
                    itemBuilder: (_) => [
                      for (final vault in _vaults)
                        CheckedPopupMenuItem(
                          value: vault['id'],
                          checked: vault['id'] == widget.selectedId,
                          child: Text(
                            vault['name']!,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            apple
                                ? CupertinoIcons.folder
                                : Icons.folder_outlined,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              current?['name'] ?? 'Select vault',
                              style: theme.textTheme.labelLarge,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            apple
                                ? CupertinoIcons.chevron_down
                                : Icons.expand_more,
                            size: 14,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_error != null)
                IconButton(
                  tooltip: _error,
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              if (widget.canManage && widget.api.canManageVaults) ...[
                IconButton(
                  tooltip: 'Create vault',
                  onPressed: _name,
                  icon: Icon(apple ? CupertinoIcons.add : Icons.add, size: 18),
                ),
                IconButton(
                  tooltip: 'Rename vault',
                  onPressed: () => _name(rename: true),
                  icon: Icon(
                    apple ? CupertinoIcons.pencil : Icons.edit_outlined,
                    size: 18,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
