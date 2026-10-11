import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import 'proposal_review_dialog.dart';

class KnowledgeProposalsScreen extends StatefulWidget {
  const KnowledgeProposalsScreen({required this.api, super.key});
  final RobotNotesClient api;

  @override
  State<KnowledgeProposalsScreen> createState() =>
      _KnowledgeProposalsScreenState();
}

class _KnowledgeProposalsScreenState extends State<KnowledgeProposalsScreen> {
  List<Map<String, dynamic>> _items = [];
  String? _state;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _items = [];
      _error = null;
    });
    try {
      final result = await widget.api.listAllKnowledgeProposals(state: _state);
      if (!mounted || generation != _generation) return;
      setState(
        () => _items = (result['items'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList(),
      );
    } on ApiException catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.message ?? 'Proposals are unavailable.');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _mutate(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } on KnowledgeConflictException {
      await _load();
      if (mounted) {
        setState(
          () => _error =
              'This proposal changed. Inspect it again before deciding.',
        );
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message ?? 'The action could not be completed.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inspect(Map<String, dynamic> summary) async {
    try {
      final id = summary['note_id'] as String;
      final proposalId = summary['proposal_id'] as String;
      final proposal = await widget.api.getKnowledgeProposal(id, proposalId);
      if (!mounted) return;
      setState(() => summary['state'] = proposal['state']);
      await showProposalReview(
        context: context,
        proposal: proposal,
        onComment: (body) => _mutate(() async {
          await widget.api.commentKnowledge(
            '/notes/$id/proposals/$proposalId/comments',
            {'record_revision': proposal['record_revision'], 'body': body},
          );
        }),
        onDecision: (decision, comment) => _mutate(() async {
          await widget.api.decideKnowledgeProposal(
            id,
            proposalId,
            decision: decision,
            recordRevision: proposal['record_revision'] as int,
            comment: comment,
          );
        }),
      );
    } on ApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message ?? 'The proposal could not be opened.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Knowledge proposals'),
      actions: [
        DropdownButton<String>(
          value: _state ?? 'active',
          items: const [
            DropdownMenuItem(value: 'active', child: Text('Active')),
            DropdownMenuItem(value: 'accepted', child: Text('Accepted')),
            DropdownMenuItem(value: 'denied', child: Text('Denied')),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  setState(() => _state = value == 'active' ? null : value);
                  _load();
                },
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, key: const Key('knowledge.proposals.error')),
          ),
        Expanded(
          child: ListView(
            children: [
              if (_items.isEmpty && !_busy && _error == null)
                ListTile(
                  title: Text(
                    _state == null
                        ? 'No active proposals'
                        : 'No $_state proposals',
                  ),
                ),
              for (final proposal in _items)
                ListTile(
                  title: Text('${proposal['title'] ?? 'Knowledge update'}'),
                  subtitle: Text(
                    '${proposal['new_note'] == true ? 'New knowledge · ' : ''}${proposal['path'] ?? ''}\n${proposal['author_label'] ?? 'Unknown author'} · ${proposalStateLabel(proposal['state'])}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _inspect(proposal),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
