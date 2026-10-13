import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../widgets/error_strip.dart';
import 'proposal_review_dialog.dart';

class ProposalReviewPanel extends StatefulWidget {
  const ProposalReviewPanel({
    required this.api,
    required this.summary,
    required this.onChanged,
    required this.onBusyChanged,
    super.key,
  });

  final RobotNotesClient api;
  final Map<String, dynamic> summary;
  final Future<void> Function(bool decided) onChanged;
  final ValueChanged<bool> onBusyChanged;

  @override
  State<ProposalReviewPanel> createState() => ProposalReviewPanelState();
}

class ProposalReviewPanelState extends State<ProposalReviewPanel> {
  final _comment = TextEditingController();
  Map<String, dynamic>? _proposal;
  Map<String, String> _acceptedBlocks = {};
  String? _acceptedContent;
  String? _error;
  bool _loading = true;
  bool _submitting = false;
  int _generation = 0;

  String get _noteId => widget.summary['note_id'] as String;
  String get _proposalId => widget.summary['proposal_id'] as String;
  List<dynamic> get _actions => _proposal?['allowed_actions'] as List? ?? [];

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _proposal = null;
    });
    try {
      final proposal = await widget.api.getKnowledgeProposal(
        _noteId,
        _proposalId,
      );
      String? acceptedContent;
      final acceptedBlocks = <String, String>{};
      final acceptedRevisions = <String, Object?>{};
      if (proposal['new_note'] != true &&
          !const {'accepted', 'denied'}.contains(proposal['state'])) {
        final note = await widget.api.getNote(_noteId);
        final blocks = await widget.api.getKnowledgeBlocks(
          _noteId,
          version: note.version,
        );
        if (blocks['version'] != note.version ||
            blocks['offset_encoding'] != 'utf-16' ||
            blocks['content_hash'] !=
                sha256.convert(utf8.encode(note.content)).toString()) {
          throw const ApiServerException(
            statusCode: 409,
            message: 'Accepted content changed. Refresh before reviewing.',
          );
        }
        for (final block
            in (blocks['blocks'] as List? ?? [])
                .whereType<Map<String, dynamic>>()) {
          final start = block['start'];
          final end = block['end'];
          if (start is! int ||
              end is! int ||
              start < 0 ||
              end < start ||
              end > note.content.length ||
              block['id'] is! String) {
            throw const ApiServerException(
              statusCode: 409,
              message: 'Block anchors changed. Refresh before reviewing.',
            );
          }
          final text = note.content.substring(start, end);
          if (block['hash'] != sha256.convert(utf8.encode(text)).toString()) {
            throw const ApiServerException(
              statusCode: 409,
              message: 'Accepted content changed. Refresh before reviewing.',
            );
          }
          acceptedBlocks[block['id'] as String] = text;
          acceptedRevisions[block['id'] as String] = block['revision'];
        }
        for (final operation
            in (proposal['operations'] as List? ?? [])
                .whereType<Map<String, dynamic>>()) {
          final blockId = operation['block_id'];
          if (blockId is String && !acceptedBlocks.containsKey(blockId)) {
            throw const ApiServerException(
              statusCode: 409,
              message: 'The accepted target is unavailable. Refresh before reviewing.',
            );
          }
          final staleBlock =
              blockId is String &&
              operation['expected_revision'] is int &&
              operation['expected_revision'] != acceptedRevisions[blockId];
          final staleNote =
              operation['type'] == 'delete_note' &&
              proposal['base_version'] != note.version;
          if (staleBlock || staleNote) {
            throw const ApiServerException(
              statusCode: 409,
              message: 'The accepted target changed. Update the proposal before reviewing.',
            );
          }
        }
        acceptedContent = note.content;
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _proposal = proposal;
        _acceptedBlocks = acceptedBlocks;
        _acceptedContent = acceptedContent;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = describeError(
            error,
            fallback: 'The proposal could not be opened.',
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _submit(String action) async {
    if (_submitting || _loading || _proposal == null) return;
    final revision = _proposal!['record_revision'] as int;
    final comment = _comment.text.trim();
    setState(() {
      _submitting = true;
      _error = null;
    });
    widget.onBusyChanged(true);
    try {
      if (action == 'comment') {
        await widget.api.commentKnowledge(
          '/notes/$_noteId/proposals/$_proposalId/comments',
          {'record_revision': revision, 'body': comment},
        );
      } else {
        await widget.api.decideKnowledgeProposal(
          _noteId,
          _proposalId,
          decision: action,
          recordRevision: revision,
          comment: comment.isEmpty ? null : comment,
        );
      }
      if (!mounted) return;
      _comment.clear();
      await refresh();
      if (mounted) {
        await widget.onChanged(action == 'approve' || action == 'deny');
      }
    } on KnowledgeConflictException {
      if (!mounted) return;
      await refresh();
      if (mounted) {
        setState(
          () => _error = 'This proposal changed. Review the refreshed changes before deciding again.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = describeError(
            error,
            fallback: 'The action could not be completed. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
      widget.onBusyChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          if (_loading || _submitting)
            const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            ErrorStrip(
              message: _error!,
              onRetry: _loading || _submitting ? null : refresh,
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator.adaptive())
                : _proposal == null
                ? const SizedBox.shrink()
                : SingleChildScrollView(
                    key: const Key('knowledge.proposals.review'),
                    padding: const EdgeInsets.all(24),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${widget.summary['title'] ?? 'Knowledge update'}',
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${widget.summary['path'] ?? ''} · ${_proposal!['author_label'] ?? 'Unknown author'}',
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 24),
                            ProposalReviewContent(
                              proposal: _proposal!,
                              acceptedBlocks: _acceptedBlocks,
                              acceptedContent: _acceptedContent,
                            ),
                            if (_actions.any(
                              (action) => const [
                                'comment',
                                'approve',
                                'deny',
                                'request_changes',
                              ].contains(action),
                            )) ...[
                              const Divider(height: 32),
                              TextField(
                                controller: _comment,
                                enabled: !_submitting,
                                minLines: 2,
                                maxLines: 5,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  labelText: 'Comment',
                                  hintText: 'Add context for your review',
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (_actions.contains('approve'))
                                    FilledButton(
                                      onPressed: _submitting
                                          ? null
                                          : () => _submit('approve'),
                                      child: const Text('Approve'),
                                    ),
                                  if (_actions.contains('request_changes'))
                                    TextButton(
                                      onPressed:
                                          _submitting ||
                                              _comment.text.trim().isEmpty
                                          ? null
                                          : () => _submit('request_changes'),
                                      child: const Text('Request changes'),
                                    ),
                                  if (_actions.contains('deny'))
                                    TextButton(
                                      onPressed: _submitting
                                          ? null
                                          : () => _submit('deny'),
                                      style: TextButton.styleFrom(
                                        foregroundColor:
                                            theme.colorScheme.error,
                                      ),
                                      child: const Text('Deny'),
                                    ),
                                  if (_actions.contains('comment'))
                                    TextButton(
                                      onPressed:
                                          _submitting ||
                                              _comment.text.trim().isEmpty
                                          ? null
                                          : () => _submit('comment'),
                                      child: const Text('Post comment'),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
