import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../notes/notes_list_screen.dart' show formatNoteTimestamp;
import '../widgets/error_strip.dart';
import 'search_controller.dart';

/// Search view. Single text field at the top; results list below.
///
/// Drives [NotesSearchController]; results render via
/// [ValueListenableBuilder]. Tapping a result calls [onResultTap] with
/// the note id so the parent can route into the note view. A failed
/// request shows the server's message; earlier results stay on screen
/// beneath it until the next query replaces them.
class SearchScreen extends StatefulWidget {
  const SearchScreen({required this.controller, this.onResultTap, super.key});

  final NotesSearchController controller;
  final ValueChanged<String>? onResultTap;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _clear() {
    _input.clear();
    widget.controller.setQuery('');
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('search.input'),
          controller: _input,
          focusNode: _inputFocus,
          autofocus: true,
          onChanged: widget.controller.setQuery,
          decoration: InputDecoration(
            hintText: 'Search notes…',
            border: InputBorder.none,
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _input,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  key: const Key('search.clear'),
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear',
                  onPressed: _clear,
                );
              },
            ),
          ),
        ),
      ),
      body: ValueListenableBuilder<SearchState>(
        valueListenable: widget.controller,
        builder: (context, state, _) {
          final trimmedQuery = state.query.trim();
          if (trimmedQuery.isEmpty) {
            return const Center(child: Text('Type to search.'));
          }
          final error = state.error;
          if (state.hits.isEmpty) {
            if (state.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (error != null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _describe(error),
                        key: const Key('search.error'),
                        textAlign: TextAlign.center,
                      ),
                      _SyntaxHint(error: error, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              );
            }
            return Center(child: Text('No matches for “$trimmedQuery”.'));
          }
          return Column(
            children: [
              if (state.isLoading) const LinearProgressIndicator(minHeight: 2),
              if (error != null) ...[
                ErrorStrip(
                  key: const Key('search.error'),
                  message: _describe(error),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _SyntaxHint(error: error),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  _matchCountLabel(state.hits.length),
                  key: const Key('search.count'),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              Expanded(
                child: ListView.separated(
                  key: const Key('search.results'),
                  itemCount: state.hits.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final hit = state.hits[index];
                    return _HitTile(
                      hit: hit,
                      onTap: widget.onResultTap == null
                          ? null
                          : () => widget.onResultTap!(hit.id),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _describe(Object error) =>
    describeError(error, fallback: 'Search failed.');

/// FTS5 syntax errors surface as a 400. Keyed off the exception type (the
/// only 400 a search request can produce), not the query text, so we never
/// guess at what in the query looked wrong.
String? _syntaxHintFor(Object error) => error is BadRequestException
    ? 'Check quotes and special characters.'
    : null;

String _matchCountLabel(int count) => count == 1 ? '1 match' : '$count matches';

/// The "Check quotes and special characters." line shown under a search
/// error, when there is one. Renders nothing for any other error type.
class _SyntaxHint extends StatelessWidget {
  const _SyntaxHint({required this.error, this.textAlign});

  final Object error;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final hint = _syntaxHintFor(error);
    if (hint == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        hint,
        key: const Key('search.hint'),
        textAlign: textAlign,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.hit, this.onTap});
  final SearchHit hit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('search.hit.${hit.id}'),
      title: Text(hit.title.isEmpty ? '(untitled)' : hit.title),
      subtitle: _SnippetText(snippet: hit.snippet),
      trailing: Text(
        formatNoteTimestamp(hit.updatedAt),
        key: Key('search.hit.${hit.id}.updated'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: onTap,
    );
  }
}

/// Renders a `<mark>…</mark>` snippet from FTS5 with the marked spans
/// visually emphasized. Only `<mark>` is interpreted; everything else is
/// rendered verbatim — the server's snippet output is the only source.
class _SnippetText extends StatelessWidget {
  const _SnippetText({required this.snippet});

  final String snippet;

  @override
  Widget build(BuildContext context) {
    final spans = parseSnippet(snippet, context);
    return RichText(
      key: const Key('search.snippet'),
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: spans,
      ),
    );
  }
}

/// Splits a snippet into [TextSpan]s with the `<mark>` ranges highlighted.
/// Exposed so tests can assert structure without poking at private widgets.
List<InlineSpan> parseSnippet(String snippet, BuildContext context) {
  final spans = <InlineSpan>[];
  var cursor = 0;
  while (cursor < snippet.length) {
    final start = snippet.indexOf('<mark>', cursor);
    if (start == -1) {
      spans.add(TextSpan(text: snippet.substring(cursor)));
      break;
    }
    if (start > cursor) {
      spans.add(TextSpan(text: snippet.substring(cursor, start)));
    }
    final end = snippet.indexOf('</mark>', start);
    if (end == -1) {
      // Malformed — emit the rest verbatim.
      spans.add(TextSpan(text: snippet.substring(start)));
      break;
    }
    final text = snippet.substring(start + '<mark>'.length, end);
    spans.add(
      TextSpan(
        text: text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
    cursor = end + '</mark>'.length;
  }
  return spans;
}
