import 'package:material_ui/material_ui.dart';

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
}) async {
  final actions = proposal['allowed_actions'] as List? ?? [];
  final draft = proposal['draft'] as Map? ?? proposal;
  List<Map<String, dynamic>> rows(Object? value) =>
      value is List ? value.whereType<Map<String, dynamic>>().toList() : [];
  Future<String?> compose(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
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
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    controller.dispose();
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Status: ${proposalStateLabel(proposal['state'])}'),
              if (proposal['accepted_version'] is int)
                Text('Accepted as version ${proposal['accepted_version']}'),
              if (proposal['new_note'] == true) ...[
                const SizedBox(height: 16),
                Text(
                  '${draft['title'] ?? 'New knowledge'}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SelectableText('${draft['content'] ?? ''}'),
              ],
              for (final operation in rows(proposal['operations']))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(switch (operation['type']) {
                        'replace' => 'Replace block',
                        'delete' => 'Delete block',
                        'insert_after' => 'Insert after block',
                        'attach_evidence' => 'Attach evidence',
                        'delete_note' => 'Delete note',
                        _ => 'Proposed update',
                      }, style: Theme.of(context).textTheme.titleSmall),
                      if (acceptedBlocks.containsKey(
                        operation['block_id'],
                      )) ...[
                        const Text('Accepted target'),
                        SelectableText(acceptedBlocks[operation['block_id']]!),
                        const SizedBox(height: 8),
                      ],
                      if (operation['text'] is String) ...[
                        const Text('Proposed text'),
                        SelectableText(operation['text'] as String),
                      ],
                    ],
                  ),
                ),
              Text('Evidence', style: Theme.of(context).textTheme.titleSmall),
              for (final evidence in rows(proposal['evidence_refs']))
                SelectableText(
                  '${evidence['kind']}: ${evidence['url'] ?? evidence['note_id'] ?? evidence['digest'] ?? evidence['reason'] ?? 'Source reference'}',
                ),
              const SizedBox(height: 16),
              for (final comment in rows(proposal['comments']))
                ListTile(
                  title: Text('${comment['author_label'] ?? 'Unknown author'}'),
                  subtitle: Text('${comment['body'] ?? ''}'),
                ),
            ],
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
