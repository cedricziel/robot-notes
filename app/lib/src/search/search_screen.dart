import 'package:flutter/material.dart';

import '../api/api_client.dart';
import 'search_controller.dart';

/// Search view. Single text field at the top; results list below.
///
/// Drives [NotesSearchController]; results render via
/// [ValueListenableBuilder]. Tapping a result calls [onResultTap] with
/// the note id so the parent can route into the note view.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    required this.controller,
    this.onResultTap,
    super.key,
  });

  final NotesSearchController controller;
  final ValueChanged<String>? onResultTap;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('search.input'),
          controller: _input,
          autofocus: true,
          onChanged: widget.controller.setQuery,
          decoration: const InputDecoration(
            hintText: 'Search notes…',
            border: InputBorder.none,
          ),
        ),
      ),
      body: ValueListenableBuilder<SearchState>(
        valueListenable: widget.controller,
        builder: (context, state, _) {
          if (state.query.trim().isEmpty) {
            return const Center(
              child: Text('Type to search.'),
            );
          }
          if (state.isLoading && state.hits.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.hits.isEmpty) {
            return const Center(child: Text('No matches.'));
          }
          return ListView.separated(
            key: const Key('search.results'),
            itemCount: state.hits.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final hit = state.hits[index];
              return _HitTile(
                hit: hit,
                onTap: widget.onResultTap == null
                    ? null
                    : () => widget.onResultTap!(hit.id),
              );
            },
          );
        },
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
