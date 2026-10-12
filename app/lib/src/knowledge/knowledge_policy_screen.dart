import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';

class KnowledgePolicyScreen extends StatefulWidget {
  const KnowledgePolicyScreen({
    required this.api,
    required this.noteId,
    required this.folder,
    super.key,
  });
  final RobotNotesClient api;
  final String noteId;
  final String folder;

  @override
  State<KnowledgePolicyScreen> createState() => _KnowledgePolicyScreenState();
}

class _KnowledgePolicyScreenState extends State<KnowledgePolicyScreen> {
  bool _folder = false;
  bool _busy = false;
  Map<String, dynamic>? _policy;
  List<Map<String, dynamic>> _principals = [];
  String? _error;
  bool? _curated;
  String? _approval;
  final Map<String, List<String>?> _access = {};
  int _generation = 0;
  static const labels = {
    'read': 'Read accepted knowledge',
    'propose': 'Propose updates',
    'review': 'Review proposals',
    'edit': 'Save accepted changes',
    'policy': 'Manage access and approval',
    'purge': 'Purge retained history',
  };

  Map<String, String> get _target => _folder
      ? {'kind': 'folder', 'path': widget.folder}
      : {'kind': 'note', 'id': widget.noteId};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _policy = null;
      _principals = [];
      _curated = null;
      _approval = null;
      _access.clear();
    });
    try {
      final policy = await widget.api.getKnowledgePolicy(_target);
      final directory = await widget.api.getKnowledgePrincipals(_target);
      if (!mounted || generation != _generation) return;
      final local = policy['local_policy'] as Map?;
      final access = local?['access'] as Map?;
      setState(() {
        _policy = policy;
        _curated = local?['curated'] as bool?;
        _approval = local?['approval'] as String?;
        _principals = (directory['items'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _access.clear();
        for (final action in labels.keys) {
          _access[action] = (access?[action] as List?)?.cast<String>();
        }
      });
    } on ApiException catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error.message ?? 'Policy information is unavailable.',
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final policy = <String, Object?>{
      if (_curated != null) 'curated': _curated,
      if (_approval != null) 'approval': _approval,
      'access': {
        for (final entry in _access.entries)
          if (entry.value != null) entry.key: entry.value,
      },
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.saveKnowledgePolicy(
        _target,
        policy,
        '${_policy!['policy_revision']}',
      );
      await _load();
    } on KnowledgeConflictException {
      await _load();
      if (mounted) {
        setState(
          () => _error = 'These rules changed. Review the refreshed settings before saving again.',
        );
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message ?? 'The rules could not be saved.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(String action) async {
    List<String>? selected = _access[action] == null
        ? null
        : List.of(_access[action]!);
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(labels[action]!),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('Inherit from parent folder'),
                    value: selected == null,
                    onChanged: (inherit) =>
                        update(() => selected = inherit ? null : []),
                  ),
                  if (selected != null) ...[
                    const Text(
                      'Only selected identities can perform this action. No selection denies everyone except the operator.',
                    ),
                    CheckboxListTile(
                      title: const Text(
                        'Any identity with the required permission',
                      ),
                      value: selected!.contains('*'),
                      onChanged: (checked) =>
                          update(() => selected = checked == true ? ['*'] : []),
                    ),
                    for (final principal in _principals)
                      CheckboxListTile(
                        title: Text('${principal['label'] ?? principal['id']}'),
                        subtitle: Text('${principal['kind'] ?? ''}'),
                        value: selected!.contains(principal['id']),
                        onChanged: selected!.contains('*')
                            ? null
                            : (checked) => update(() {
                                if (checked == true) {
                                  selected!.add(principal['id'] as String);
                                } else {
                                  selected!.remove(principal['id']);
                                }
                              }),
                      ),
                    for (final id in selected!.where(
                      (id) =>
                          id != '*' &&
                          !_principals.any(
                            (principal) => principal['id'] == id,
                          ),
                    ))
                      ListTile(
                        title: Text(
                          id == '*'
                              ? 'All authorized identities'
                              : 'Previously selected identity',
                        ),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => update(() => selected!.remove(id)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (changed == true && mounted) setState(() => _access[action] = selected);
  }

  @override
  Widget build(BuildContext context) {
    final effective = _policy?['effective_policy'] as Map?;
    final allowed = (_policy?['allowed_actions'] as List? ?? []).contains(
      'policy',
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Knowledge rules')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('This note')),
              ButtonSegment(value: true, label: Text('Folder')),
            ],
            selected: {_folder},
            onSelectionChanged: _busy
                ? null
                : (selection) {
                    setState(() => _folder = selection.single);
                    _load();
                  },
          ),
          const SizedBox(height: 24),
          Text(
            'Effective rules: ${effective?['curated'] == true ? 'Curated knowledge' : 'Ordinary note'} · ${effective?['approval'] == 'evidence_no_conflict' ? 'Verified source attachments may be accepted automatically' : 'Human approval required'}',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('curated:$_folder:$_curated'),
            initialValue: _curated == null
                ? 'inherit'
                : _curated!
                ? 'curated'
                : 'ordinary',
            decoration: const InputDecoration(
              labelText: 'Knowledge designation',
            ),
            items: const [
              DropdownMenuItem(value: 'inherit', child: Text('Inherit')),
              DropdownMenuItem(
                value: 'curated',
                child: Text('Curated knowledge'),
              ),
              DropdownMenuItem(value: 'ordinary', child: Text('Ordinary note')),
            ],
            onChanged: _busy || !allowed
                ? null
                : (value) => setState(
                    () => _curated = value == 'inherit'
                        ? null
                        : value == 'curated',
                  ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('approval:$_folder:$_approval'),
            initialValue: _approval ?? 'inherit',
            decoration: const InputDecoration(
              labelText: 'Agent update approval',
            ),
            items: const [
              DropdownMenuItem(value: 'inherit', child: Text('Inherit')),
              DropdownMenuItem(value: 'human', child: Text('Human approval')),
              DropdownMenuItem(
                value: 'evidence_no_conflict',
                child: Text('Accept verified source links automatically'),
              ),
            ],
            onChanged: _busy || !allowed
                ? null
                : (value) => setState(
                    () => _approval = value == 'inherit' ? null : value,
                  ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Source checks verify availability and access. Changes to note text still require human approval.',
          ),
          for (final action in labels.keys)
            ListTile(
              title: Text(labels[action]!),
              subtitle: Text(
                _access[action] == null
                    ? 'Inherited'
                    : '${_access[action]!.length} selected identities',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy || !allowed ? null : () => _choose(action),
            ),
          FilledButton(
            onPressed: _busy || !allowed ? null : _save,
            child: const Text('Save rules'),
          ),
        ],
      ),
    );
  }
}
