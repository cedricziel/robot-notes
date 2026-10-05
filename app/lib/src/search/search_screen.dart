import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../notes/notes_list_screen.dart' show formatNoteTimestamp;
import '../widgets/empty_state.dart';
import '../widgets/error_strip.dart';
import 'search_controller.dart';

/// Search view. Single text field at the top; results list below.
///
/// Drives [NotesSearchController]; results render via
/// [ValueListenableBuilder]. Tapping a result calls [onResultTap] with
/// the note id so the parent can route into the note view. A failed
/// request shows the server's message; earlier results stay on screen
/// beneath it until the next query replaces them. Before the user types
/// anything, [recentNotes] (already loaded and sorted by the caller —
/// typically the notes list, already most-recently-updated-first) fills
/// the empty state instead of a bare hint.
///
/// Not a page: there is no [Scaffold] or [AppBar] here. The widget is a
/// plain [Material] surface that fills whatever its parent gives it, so
/// the router can host it in a top sheet on phones and a centered
/// [Dialog] on wider windows without a second app bar (or a spurious
/// back arrow) appearing inside the overlay. [onClose] adds a close
/// button to the header for hosts that have no other affordance.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    required this.controller,
    this.onResultTap,
    this.onClose,
    this.autofocus = true,
    this.recentNotes = const <NoteMeta>[],
    super.key,
  });

  final NotesSearchController controller;
  final ValueChanged<String>? onResultTap;

  /// Invoked by the header's close button. `null` hides the button (the
  /// host is expected to provide its own dismissal, e.g. a scrim tap).
  final VoidCallback? onClose;
  final bool autofocus;

  /// Shown as a "Recent" section while the query is empty. `null`/empty
  /// falls back to the plain "Type to search." hint.
  final List<NoteMeta> recentNotes;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final TextEditingController _input;
  late final FocusNode _inputFocus = FocusNode(onKeyEvent: _onKey);
  int _selected = -1;
  final Map<String, GlobalKey> _resultKeys = {};

  List<String> get _visibleIds => widget.controller.value.query.trim().isEmpty
      ? widget.recentNotes.take(8).map((note) => note.id).toList()
      : widget.controller.value.hits.map((hit) => hit.id).toList();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        widget.onClose != null) {
      widget.onClose!();
      return KeyEventResult.handled;
    }
    final ids = _visibleIds;
    if (ids.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
      setState(
        () =>
            _selected = (_selected + (down ? 1 : -1)).clamp(0, ids.length - 1),
      );
      final selectedContext = _resultKeys[ids[_selected]]?.currentContext;
      if (selectedContext != null) {
        Scrollable.ensureVisible(
          selectedContext,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
        );
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        _selected >= 0 &&
        _selected < ids.length) {
      widget.onResultTap?.call(ids[_selected]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _queryChanged(String query) {
    setState(() => _selected = -1);
    widget.controller.setQuery(query);
  }

  Widget _selection(String id, int index, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    final selected = index == _selected;
    return Padding(
      key: _resultKeys.putIfAbsent(id, GlobalKey.new),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected ? scheme.primary : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Semantics(selected: selected, child: child),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.controller.value.query);
  }

  @override
  void didUpdateWidget(SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autofocus && !oldWidget.autofocus) _inputFocus.requestFocus();
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _clear() {
    _input.clear();
    _queryChanged('');
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _buildHeader(context),
          const Divider(height: 1),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.search, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const Key('search.input'),
              controller: _input,
              focusNode: _inputFocus,
              autofocus: widget.autofocus,
              onChanged: _queryChanged,
              decoration: const InputDecoration(
                hintText: 'Search notes…',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
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
          if (widget.onClose != null)
            IconButton(
              key: const Key('search.close'),
              icon: const Icon(Icons.close),
              tooltip: 'Close',
              onPressed: widget.onClose,
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return ValueListenableBuilder<SearchState>(
      valueListenable: widget.controller,
      builder: (context, state, _) {
        final trimmedQuery = state.query.trim();
        if (trimmedQuery.isEmpty) {
          if (widget.recentNotes.isEmpty) {
            return const EmptyState(
              icon: Icons.search,
              title: 'Type to search.',
            );
          }
          return _RecentSection(
            notes: widget.recentNotes,
            onTap: widget.onResultTap,
            selectionBuilder: _selection,
          );
        }
        final error = state.error;
        if (state.hits.isEmpty) {
          if (state.isLoading) {
            return const Center(child: CircularProgressIndicator.adaptive());
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
          return EmptyState(
            icon: Icons.search_off,
            title: 'No matches for “$trimmedQuery”.',
          );
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
              child: SingleChildScrollView(
                key: const Key('search.results'),
                child: Column(
                  children: [
                    for (var index = 0; index < state.hits.length; index++)
                      _selection(
                        state.hits[index].id,
                        index,
                        _HitTile(
                          hit: state.hits[index],
                          onTap: widget.onResultTap == null
                              ? null
                              : () => widget.onResultTap!(state.hits[index].id),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
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

/// Fills the empty state before the user types anything: a short list of
/// recently-updated notes, so search never opens to a blank page.
class _RecentSection extends StatelessWidget {
  const _RecentSection({
    required this.notes,
    this.onTap,
    required this.selectionBuilder,
  });
  final Widget Function(String, int, Widget) selectionBuilder;

  final List<NoteMeta> notes;
  final ValueChanged<String>? onTap;

  /// Caps how many recent notes to show — this is a quick jumping-off
  /// point, not a second notes list.
  static const _maxShown = 8;

  @override
  Widget build(BuildContext context) {
    final shown = notes.take(_maxShown).toList(growable: false);
    return SingleChildScrollView(
      key: const Key('search.recent'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Recent',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          for (var index = 0; index < shown.length; index++)
            selectionBuilder(
              shown[index].id,
              index,
              ListTile(
                key: Key('search.recent.${shown[index].id}'),
                title: Text(
                  shown[index].title.isEmpty
                      ? '(untitled)'
                      : shown[index].title,
                ),
                trailing: Text(
                  formatNoteTimestamp(shown[index].updatedAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onTap: onTap == null ? null : () => onTap!(shown[index].id),
              ),
            ),
        ],
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
      textScaler: MediaQuery.textScalerOf(context),
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
