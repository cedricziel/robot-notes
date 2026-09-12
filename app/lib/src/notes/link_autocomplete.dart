import 'dart:async';

import 'package:flutter/foundation.dart';

/// An in-progress `[[title]]` (or `[[title|alias]]`) the user is currently
/// typing: the span from the opening `[[` (exclusive of the brackets
/// themselves — [start] points at the first `[`) to the cursor.
@immutable
class LinkTrigger {
  const LinkTrigger({
    required this.start,
    required this.end,
    required this.query,
    this.alias,
  });

  /// Index of the trigger's opening `[[` in the source text.
  final int start;

  /// Cursor position when this trigger was detected — also the end of the
  /// span [insertLink] replaces.
  final int end;

  /// Text typed after `[[` (or after `[[` up to a `|`) — used to filter
  /// suggestions.
  final String query;

  /// Text typed after a `|`, if the user has typed one. When selecting a
  /// suggestion, this is preserved as the link's display alias.
  final String? alias;
}

/// Detects whether the cursor at [cursor] in [text] sits inside an
/// unclosed `[[...` — i.e. the nearest `[[` before the cursor has no `]]`
/// between it and the cursor. Returns `null` when there is no such open
/// trigger (nothing typed, or the link was already closed with `]]`).
LinkTrigger? detectLinkTrigger(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  final before = text.substring(0, cursor);
  final openIdx = before.lastIndexOf('[[');
  if (openIdx == -1) return null;
  final between = before.substring(openIdx + 2);
  if (between.contains(']]')) return null;
  final pipeIdx = between.indexOf('|');
  if (pipeIdx == -1) {
    return LinkTrigger(start: openIdx, end: cursor, query: between);
  }
  return LinkTrigger(
    start: openIdx,
    end: cursor,
    query: between.substring(0, pipeIdx),
    alias: between.substring(pipeIdx + 1),
  );
}

/// Result of [insertLink]: the full new content and where the cursor
/// should land afterwards.
@immutable
class LinkInsertion {
  const LinkInsertion({required this.text, required this.cursor});
  final String text;
  final int cursor;
}

/// Replaces [trigger]'s span in [text] with `[[title]]`, or `[[title|alias]]`
/// when the user had already typed a `|` (its text is preserved verbatim as
/// the alias). The cursor lands right after the inserted `]]`.
LinkInsertion insertLink(String text, LinkTrigger trigger, String title) {
  final alias = trigger.alias;
  final replacement = alias == null ? '[[$title]]' : '[[$title|$alias]]';
  final newText = text.replaceRange(trigger.start, trigger.end, replacement);
  return LinkInsertion(
    text: newText,
    cursor: trigger.start + replacement.length,
  );
}

/// Snapshot of [LinkAutocompleteController] state.
@immutable
class LinkAutocompleteState {
  const LinkAutocompleteState({
    this.isOpen = false,
    this.trigger,
    this.suggestions = const <String>[],
  });

  static const closed = LinkAutocompleteState();

  final bool isOpen;
  final LinkTrigger? trigger;
  final List<String> suggestions;
}

/// Drives the `[[`-triggered link autocomplete in the content editor.
///
/// Feed every content change through [onChanged] with the current text and
/// cursor offset. When the cursor sits inside an open `[[...` trigger, this
/// debounces a title lookup (via the injected [search], typically backed by
/// `GET /search`) and exposes the matches for the editor to render as a
/// selectable list; [insertLink] (a free function, not a method here) turns
/// a selection back into text once the caller has one.
class LinkAutocompleteController extends ValueNotifier<LinkAutocompleteState> {
  LinkAutocompleteController({
    required Future<List<String>> Function(String query) search,
    Duration debounce = const Duration(milliseconds: 150),
    Future<void> Function(Duration)? scheduler,
  }) : _search = search,
       _debounce = debounce,
       _scheduler = scheduler ?? Future<void>.delayed,
       super(LinkAutocompleteState.closed);

  final Future<List<String>> Function(String query) _search;
  final Duration _debounce;
  final Future<void> Function(Duration) _scheduler;
  int _gen = 0;
  bool _disposed = false;

  /// Call on every content change with the full text and the cursor's
  /// current offset (e.g. a `TextEditingController`'s
  /// `selection.baseOffset`).
  void onChanged(String text, int cursor) {
    if (_disposed) return;
    final trigger = detectLinkTrigger(text, cursor);
    _gen += 1;
    final myGen = _gen;
    if (trigger == null) {
      value = LinkAutocompleteState.closed;
      return;
    }
    value = LinkAutocompleteState(
      isOpen: true,
      trigger: trigger,
      // Keep whatever suggestions were already showing while the new
      // lookup is in flight, rather than flashing an empty list on every
      // keystroke.
      suggestions: value.suggestions,
    );
    if (trigger.query.trim().isEmpty) return;
    unawaited(_runSearch(myGen, trigger, trigger.query));
  }

  Future<void> _runSearch(int gen, LinkTrigger trigger, String query) async {
    await _scheduler(_debounce);
    if (_disposed || gen != _gen) return;
    final results = await _search(query);
    if (_disposed || gen != _gen) return;
    value = LinkAutocompleteState(
      isOpen: true,
      trigger: trigger,
      suggestions: results,
    );
  }

  /// Dismisses the autocomplete (e.g. after a selection is inserted, or the
  /// user types past it).
  void close() {
    if (_disposed) return;
    _gen += 1;
    value = LinkAutocompleteState.closed;
  }

  @override
  void dispose() {
    _disposed = true;
    _gen += 1;
    super.dispose();
  }
}
