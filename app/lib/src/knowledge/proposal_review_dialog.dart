import 'package:material_ui/material_ui.dart';

String _sourceLabel(Map<String, dynamic> source) => switch (source['kind']) {
  'note_revision' => 'Note ${source['note_id']} · version ${source['version']}',
  'block_revision' =>
    'Note ${source['note_id']} · version ${source['version']} · block ${source['block_id']} · revision ${source['block_revision']}',
  'archive' => 'Evidence archive · ${source['digest']}',
  'url' => '${source['url']}',
  'conversation' => [
    'Conversation ${source['session_id']}',
    if (source['turn_id'] != null) 'turn ${source['turn_id']}',
    if (source['tool_call_id'] != null) 'tool call ${source['tool_call_id']}',
    if (source['task_id'] != null) 'task ${source['task_id']}',
  ].join(' · '),
  _ => '${source['reason'] ?? 'Source not recorded'}',
};

String proposalStateLabel(Object? state) => switch (state) {
  'pending' => 'Awaiting review',
  'changes_requested' => 'Changes requested',
  'needs_re_review' => 'Needs another review',
  'conflicted' => 'Conflict needs resolution',
  'accepted' => 'Accepted',
  'denied' => 'Denied',
  _ => 'Unknown status',
};

Future<void> showProposalReview({
  required BuildContext context,
  required Map<String, dynamic> proposal,
  required Future<void> Function(String decision, String? comment) onDecision,
  required Future<void> Function(String body) onComment,
  Map<String, String> acceptedBlocks = const {},
  String? acceptedContent,
}) async {
  final actions = proposal['allowed_actions'] as List? ?? [];
  Future<String?> compose(String title) async {
    var comment = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: TextFormField(
            onChanged: (value) => comment = value,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(labelText: 'Comment'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, comment),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    return result;
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        'Proposal by ${proposal['author_label'] ?? 'Unknown author'}',
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: ProposalReviewContent(
            proposal: proposal,
            acceptedBlocks: acceptedBlocks,
            acceptedContent: acceptedContent,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
        if (actions.contains('comment'))
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final body = await compose('Comment on proposal');
              if (body == null || body.trim().isEmpty || !context.mounted) {
                return;
              }
              await onComment(body);
            },
            child: const Text('Comment'),
          ),
        for (final decision in [
          'deny',
          'request_changes',
          'approve',
        ].where(actions.contains))
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final comment = decision == 'approve'
                  ? null
                  : await compose(
                      decision == 'deny' ? 'Deny proposal' : 'Request changes',
                    );
              if (!context.mounted ||
                  decision != 'approve' && comment == null) {
                return;
              }
              await onDecision(decision, comment);
            },
            child: Text(switch (decision) {
              'approve' => 'Approve',
              'deny' => 'Deny',
              _ => 'Request changes',
            }),
          ),
      ],
    ),
  );
}

class ProposalReviewContent extends StatelessWidget {
  const ProposalReviewContent({
    required this.proposal,
    this.acceptedBlocks = const {},
    this.acceptedContent,
    super.key,
  });

  final Map<String, dynamic> proposal;
  final Map<String, String> acceptedBlocks;
  final String? acceptedContent;

  @override
  Widget build(BuildContext context) {
    final draft = proposal['draft'] as Map? ?? proposal;
    List<Map<String, dynamic>> rows(Object? value) =>
        value is List ? value.whereType<Map<String, dynamic>>().toList() : [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Text(
                  proposalStateLabel(proposal['state']),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ),
            if (proposal['author_agent_origin'] == true ||
                proposal['author_kind'] == 'agent')
              const Text('Agent proposal'),
          ],
        ),
        if (proposal['accepted_version'] is int)
          Text('Accepted as version ${proposal['accepted_version']}'),
        if (proposal['new_note'] == true) ...[
          const SizedBox(height: 16),
          _ReviewText(
            label: 'New knowledge',
            text: '${draft['content'] ?? ''}',
            proposed: true,
          ),
        ],
        for (final operation in rows(proposal['operations']))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(switch (operation['type']) {
                  'replace' => 'Replace block',
                  'delete' => 'Delete block',
                  'insert_after' => 'Insert after block',
                  'attach_evidence' => 'Attach evidence',
                  'delete_note' => 'Delete note',
                  _ => 'Proposed update',
                }, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 12),
                if (operation['type'] == 'delete_note' &&
                    acceptedContent != null) ...[
                  _ReviewText(label: 'Accepted target', text: acceptedContent!),
                  const SizedBox(height: 8),
                ],
                if (acceptedBlocks.containsKey(operation['block_id'])) ...[
                  _ReviewText(
                    label: 'Accepted target',
                    text: acceptedBlocks[operation['block_id']]!,
                  ),
                  const SizedBox(height: 8),
                ],
                if (operation['text'] is String) ...[
                  _ReviewText(
                    label: 'Proposed text',
                    text: operation['text'] as String,
                    proposed: true,
                  ),
                ],
                if (rows(operation['evidence_refs']).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Supporting evidence'),
                  for (final source in rows(operation['evidence_refs']))
                    SelectableText(_sourceLabel(source)),
                ],
                if (rows(operation['supersedes']).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Superseded sources'),
                  for (final source in rows(operation['supersedes']))
                    SelectableText(_sourceLabel(source)),
                ],
              ],
            ),
          ),
        const Divider(height: 32),
        Text('Evidence', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (rows(proposal['evidence_refs']).isEmpty)
          Text(
            'No additional evidence attached.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        for (final evidence in rows(proposal['evidence_refs']))
          SelectableText(_sourceLabel(evidence)),
        const Divider(height: 32),
        Text('Discussion', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (rows(proposal['comments']).isEmpty)
          Text(
            'No comments yet.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        for (final comment in rows(proposal['comments']))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${comment['author_label'] ?? 'Unknown author'}'),
            subtitle: Text('${comment['body'] ?? ''}'),
          ),
      ],
    );
  }
}

class _ReviewText extends StatelessWidget {
  const _ReviewText({
    required this.label,
    required this.text,
    this.proposed = false,
  });
  final String label;
  final String text;
  final bool proposed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: proposed
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(text, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
