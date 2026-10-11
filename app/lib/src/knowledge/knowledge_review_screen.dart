import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import 'knowledge_policy_screen.dart';

class KnowledgeReviewScreen extends StatefulWidget {
  const KnowledgeReviewScreen({
    required this.api,
    required this.note,
    required this.onAcceptedChange,
    super.key,
  });
  final RobotNotesClient api;
  final Note note;
  final Future<void> Function() onAcceptedChange;

  @override
  State<KnowledgeReviewScreen> createState() => _KnowledgeReviewScreenState();
}

class _KnowledgeReviewScreenState extends State<KnowledgeReviewScreen> {
  late Note _note = widget.note;
  Map<String, dynamic>? _permissions;
  Map<String, dynamic>? _blocks;
  Map<String, dynamic>? _comments;
  List<Map<String, dynamic>> _proposals = [];
  List<Map<String, dynamic>> _history = [];
  String? _error;
  bool _busy = false;
  int _generation = 0;

  bool _can(String action) =>
      (_permissions?['allowed_actions'] as List? ?? []).contains(action);
  List<Map<String, dynamic>> _rows(Object? value) =>
      value is List ? value.whereType<Map<String, dynamic>>().toList() : [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _permissions = null;
      _proposals = [];
      _blocks = null;
      _comments = null;
      _history = [];
    });
    try {
      final currentNote = await widget.api.getNote(_note.id);
      final permissions = await widget.api.getKnowledgePermissions(_note.id);
      if (!mounted || generation != _generation) return;
      setState(() {
        _permissions = permissions;
        _note = currentNote;
      });
      final proposals = await widget.api.listKnowledgeProposals(_note.id);
      final blocks = await widget.api.getKnowledgeBlocks(
        _note.id,
        version: currentNote.version,
      );
      if (blocks['content_hash'] !=
              sha256.convert(utf8.encode(currentNote.content)).toString() ||
          blocks['offset_encoding'] != 'utf-16') {
        throw const ApiServerException(
          statusCode: 409,
          message: 'Block anchors changed. Refresh the accepted note before reviewing.',
        );
      }
      final comments = await widget.api.getKnowledgeComments(_note.id);
      final history = await widget.api.getKnowledgeHistory(_note.id);
      if (!mounted || generation != _generation) return;
      setState(() {
        _note = currentNote;
        _permissions = permissions;
        _proposals = _rows(proposals['items']);
        _blocks = blocks;
        _comments = comments;
        _history = _rows(history['revisions']);
      });
    } on ApiException catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error.message ?? 'Review information is unavailable.',
        );
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
      await _refresh();
    } on KnowledgeConflictException {
      await _refresh();
      if (mounted) {
        setState(
          () => _error = 'This review changed. Inspect the refreshed proposal before deciding again.',
        );
      }
    } on VersionConflictException {
      await _refresh();
      if (mounted) {
        setState(
          () => _error =
              'The accepted note changed. Reopen review before restoring.',
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

  Future<String?> _text(
    String title, {
    String initial = '',
    String label = 'Comment',
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 8,
            minLines: 3,
            decoration: InputDecoration(labelText: label),
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
    return value;
  }

  Future<void> _inspect(Map<String, dynamic> summary) async {
    try {
      final proposal = await widget.api.getKnowledgeProposal(
        _note.id,
        summary['proposal_id'] as String,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            'Proposal by ${proposal['author_label'] ?? 'Unknown author'}',
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Status: ${proposal['state']}'),
                  const SizedBox(height: 16),
                  for (final operation in _rows(proposal['operations']))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${operation['type'] ?? operation['op']}',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          SelectableText(
                            '${operation['content'] ?? operation['text'] ?? ''}',
                          ),
                        ],
                      ),
                    ),
                  Text(
                    'Evidence',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final evidence in _rows(proposal['evidence_refs']))
                    SelectableText(
                      '${evidence['kind']}: ${evidence['url'] ?? evidence['note_id'] ?? evidence['digest'] ?? evidence['reason'] ?? 'Source reference'}',
                    ),
                  const SizedBox(height: 16),
                  for (final comment in _rows(proposal['comments']))
                    ListTile(
                      title: Text(
                        '${comment['author_label'] ?? 'Unknown author'}',
                      ),
                      subtitle: Text('${comment['body'] ?? ''}'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            if (_can('read') && (_can('propose') || _can('review')))
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  final body = await _text('Comment on proposal');
                  if (body == null || body.trim().isEmpty || !mounted) return;
                  await _mutate(() async {
                    await widget.api.commentKnowledge(
                      '/notes/${_note.id}/proposals/${proposal['proposal_id']}/comments',
                      {
                        'record_revision': proposal['record_revision'],
                        'body': body,
                      },
                    );
                  });
                },
                child: const Text('Comment'),
              ),
            if (_can('review') &&
                [
                  'pending',
                  'changes_requested',
                  'needs_re_review',
                  'conflicted',
                ].contains(proposal['state'])) ...[
              for (final decision in [
                'deny',
                'request_changes',
                if ([
                  'pending',
                  'changes_requested',
                ].contains(proposal['state']))
                  'approve',
              ])
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          Navigator.pop(context);
                          final comment = decision == 'approve'
                              ? null
                              : await _text(
                                  decision == 'deny'
                                      ? 'Deny proposal'
                                      : 'Request changes',
                                );
                          if (decision != 'approve' && comment == null ||
                              !mounted) {
                            return;
                          }
                          await _mutate(() async {
                            await widget.api.decideKnowledgeProposal(
                              _note.id,
                              proposal['proposal_id'] as String,
                              decision: decision,
                              recordRevision:
                                  proposal['record_revision'] as int,
                              comment: comment,
                            );
                            if (decision == 'approve') {
                              await widget.onAcceptedChange();
                            }
                          });
                        },
                  child: Text(switch (decision) {
                    'approve' => 'Approve',
                    'deny' => 'Deny',
                    _ => 'Request changes',
                  }),
                ),
            ],
          ],
        ),
      );
    } on ApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message ?? 'The proposal could not be opened.',
        );
      }
    }
  }

  String _source(Map<String, dynamic> block) {
    final start = block['start'];
    final end = block['end'];
    if (_blocks?['version'] != _note.version ||
        start is! int ||
        end is! int ||
        start < 0 ||
        end < start ||
        end > _note.content.length) {
      return '';
    }
    final source = _note.content.substring(start, end);
    return block['hash'] == sha256.convert(utf8.encode(source)).toString()
        ? source
        : '';
  }

  Future<void> _blockAction(Map<String, dynamic> block, bool proposal) async {
    if (_source(block).isEmpty) return;
    final text = await _text(
      proposal ? 'Propose block update' : 'Comment on block',
      initial: proposal ? _source(block) : '',
      label: proposal ? 'Proposed Markdown' : 'Comment',
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _mutate(() async {
      if (proposal) {
        await widget.api.createKnowledgeProposal(_note.id, {
          'base_version': _note.version,
          'operations': [
            {
              'type': 'replace',
              'block_id': block['id'],
              'expected_revision': block['revision'],
              'text': text,
            },
          ],
          'evidence_refs': [
            {'kind': 'unknown', 'reason': 'source_not_recorded'},
          ],
        });
      } else {
        await widget.api.commentKnowledge('/notes/${_note.id}/comments', {
          'record_revision': _comments?['record_revision'],
          'body': text,
          'block_id': block['id'],
          'block_revision': block['revision'],
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge review'),
        actions: [
          if (_can('policy'))
            IconButton(
              tooltip: 'Knowledge rules',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => KnowledgePolicyScreen(
                            api: widget.api,
                            noteId: _note.id,
                            folder: _note.path,
                          ),
                        ),
                      );
                      if (mounted) await _refresh();
                    },
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Proposals'),
            Tab(text: 'Blocks and comments'),
            Tab(text: 'History'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, key: const Key('knowledge.error')),
            ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  children: [
                    if (_proposals.isEmpty && !_busy)
                      const ListTile(title: Text('No proposals')),
                    for (final proposal in _proposals)
                      ListTile(
                        title: Text(
                          '${proposal['author_label'] ?? 'Unknown author'}',
                        ),
                        subtitle: Text(
                          '${proposal['state']} · ${proposal['author_kind'] ?? ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _busy ? null : () => _inspect(proposal),
                      ),
                  ],
                ),
                ListView(
                  children: [
                    for (final block in _rows(_blocks?['blocks']))
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(_source(block)),
                              Wrap(
                                children: [
                                  if (_can('propose'))
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _blockAction(block, true),
                                      child: const Text('Propose update'),
                                    ),
                                  if (_can('read') &&
                                      (_can('propose') || _can('review')))
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _blockAction(block, false),
                                      child: const Text('Comment'),
                                    ),
                                ],
                              ),
                              for (final comment
                                  in _rows(_comments?['items']).where(
                                    (comment) =>
                                        comment['block_id'] == block['id'],
                                  ))
                                ListTile(
                                  title: Text(
                                    '${comment['author_label'] ?? 'Unknown author'}',
                                  ),
                                  subtitle: Text(
                                    '${comment['body']}\n${comment['anchor_status'] ?? ''}',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    for (final comment in _rows(_comments?['items']).where(
                      (comment) => !_rows(_blocks?['blocks'])
                          .any((block) => block['id'] == comment['block_id']),
                    ))
                      ListTile(
                        title: Text(
                          '${comment['author_label'] ?? 'Unknown author'}',
                        ),
                        subtitle: Text(
                          '${comment['body']}\nOriginal block is no longer present.',
                        ),
                      ),
                  ],
                ),
                ListView(
                  children: [
                    for (final revision in _history)
                      ListTile(
                        title: Text('Version ${revision['version']}'),
                        subtitle: Text(
                          '${revision['recorded_at'] ?? ''}${revision['deleted'] == true ? ' · Deleted' : ''}',
                        ),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('Version ${revision['version']}'),
                            content: SizedBox(
                              width: 640,
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  '${revision['markdown'] ?? ''}',
                                ),
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                              if (_can('edit'))
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () async {
                                          Navigator.pop(context);
                                          await _mutate(() async {
                                            await widget.api
                                                .restoreKnowledgeHistory(
                                                  _note.id,
                                                  version:
                                                      revision['version']
                                                          as int,
                                                  currentVersion: _note.version,
                                                );
                                            await widget.onAcceptedChange();
                                          });
                                        },
                                  child: const Text('Restore as new version'),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
