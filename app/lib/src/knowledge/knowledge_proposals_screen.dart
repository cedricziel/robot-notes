import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;

import '../api/api_client.dart';
import '../widgets/adaptive.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_strip.dart';
import 'proposal_review_panel.dart';
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
  Map<String, dynamic>? _selected;
  GlobalKey<ProposalReviewPanelState> _reviewKey = GlobalKey();
  bool _submitting = false;

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
    });
    try {
      final result = await widget.api.listAllKnowledgeProposals(state: _state);
      if (!mounted || generation != _generation) return;
      setState(
        () => _items = (result['items'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList(),
      );
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = describeError(
            error,
            fallback: 'Proposals are unavailable.',
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _select(Map<String, dynamic> proposal) {
    if (_submitting ||
        _selected?['note_id'] == proposal['note_id'] &&
            _selected?['proposal_id'] == proposal['proposal_id']) {
      return;
    }
    setState(() {
      _selected = proposal;
      _reviewKey = GlobalKey();
    });
  }

  Future<void> _changed(bool decided) async {
    await _load();
    if (!mounted) return;
    if (decided && _state == null) setState(() => _selected = null);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1000;
      final reviewing = _selected != null;
      final apple = useCupertino(context);
      final filterLabel = switch (_state) {
        'accepted' => 'Accepted',
        'denied' => 'Denied',
        _ => 'Active',
      };
      final review = reviewing
          ? ProposalReviewPanel(
              key: _reviewKey,
              api: widget.api,
              summary: _selected!,
              onChanged: _changed,
              onBusyChanged: (busy) {
                if (mounted) setState(() => _submitting = busy);
              },
            )
          : const EmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Select a proposal',
              message: 'Review proposed changes and their supporting evidence.',
            );
      return PopScope(
        canPop: !_submitting && (!reviewing || wide),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !_submitting) setState(() => _selected = null);
        },
        child: Scaffold(
          appBar: AppBar(
            leading: reviewing && !wide
                ? IconButton(
                    tooltip: 'Back to proposals',
                    icon: Icon(adaptiveBackIcon(context)),
                    onPressed: _submitting
                        ? null
                        : () => setState(() => _selected = null),
                  )
                : null,
            title: Text(
              reviewing && !wide ? 'Review proposal' : 'Knowledge proposals',
            ),
            actions: [
              if (!reviewing || wide)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: AdaptiveMenu(
                    tooltip: 'Filter proposals',
                    enabled: !_busy && !_submitting,
                    entries: [
                      for (final state in [null, 'accepted', 'denied'])
                        AdaptiveMenuEntry(
                          label: state == null
                              ? 'Active'
                              : state == 'accepted'
                              ? 'Accepted'
                              : 'Denied',
                          selected: _state == state,
                          onSelected: () {
                            setState(() {
                              _state = state;
                              _selected = null;
                              _items = [];
                            });
                            _load();
                          },
                        ),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(filterLabel),
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more, size: 18),
                      ],
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _busy || _submitting
                    ? null
                    : () {
                        _load();
                        _reviewKey.currentState?.refresh();
                      },
                icon: Icon(
                  apple ? CupertinoIcons.arrow_clockwise : Icons.refresh,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 340, child: _inbox(context)),
                    const VerticalDivider(width: 1),
                    Expanded(child: review),
                  ],
                )
              : reviewing
              ? review
              : _inbox(context),
        ),
      );
    },
  );

  Widget _inbox(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            ErrorStrip(
              key: const Key('knowledge.proposals.error'),
              message: _error!,
              onRetry: _busy ? null : _load,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '${_items.length} ${_items.length == 1 ? 'proposal' : 'proposals'}',
              style: theme.textTheme.labelMedium,
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? _busy
                      ? const Center(
                          child: CircularProgressIndicator.adaptive(),
                        )
                      : _error != null
                      ? const SizedBox.shrink()
                      : EmptyState(
                          icon: useCupertino(context)
                              ? CupertinoIcons.tray
                              : Icons.inbox_outlined,
                          title: _state == null
                              ? 'No active proposals'
                              : 'No $_state proposals',
                          message: _state == null
                              ? 'New knowledge updates will appear here for review.'
                              : 'Proposals you ${_state == 'accepted' ? 'accept' : 'deny'} will appear here.',
                        )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final proposal = _items[index];
                      final selected =
                          _selected?['note_id'] == proposal['note_id'] &&
                          _selected?['proposal_id'] == proposal['proposal_id'];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: ListTile(
                          key: ValueKey(
                            'proposal.${proposal['note_id']}.${proposal['proposal_id']}',
                          ),
                          selected: selected,
                          selectedTileColor: theme.colorScheme.primaryContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          title: Text(
                            '${proposal['title'] ?? 'Knowledge update'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${proposal['new_note'] == true ? 'New knowledge · ' : ''}${proposal['path'] ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${proposal['author_label'] ?? 'Unknown author'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  proposalStateLabel(proposal['state']),
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: _submitting ? null : () => _select(proposal),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
