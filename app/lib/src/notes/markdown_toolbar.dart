import 'package:flutter/material.dart';

/// Wraps the current selection in [value] with [marker] on both sides
/// (e.g. `**` for bold, `*` for italic). With a non-empty selection, the
/// wrapped text stays selected so the marker is visible and the user can
/// keep typing over it; with a collapsed selection (just a cursor), an
/// empty `marker` + `marker` pair is inserted with the cursor placed
/// between them, ready to type into.
TextEditingValue wrapSelection(TextEditingValue value, String marker) {
  final selection = value.selection;
  final text = value.text;
  final selected = selection.textInside(text);
  final before = selection.textBefore(text);
  final after = selection.textAfter(text);

  final newText = '$before$marker$selected$marker$after';
  if (selected.isEmpty) {
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: before.length + marker.length),
    );
  }
  return TextEditingValue(
    text: newText,
    selection: TextSelection(
      baseOffset: before.length + marker.length,
      extentOffset: before.length + marker.length + selected.length,
    ),
  );
}

/// Inserts a markdown link at the current selection in [value]. A
/// non-empty selection becomes the link text (`[selected](url)`), leaving
/// the `url` placeholder selected so it's the first thing overwritten; a
/// collapsed selection inserts a full `[title](url)` template with
/// `title` selected instead.
TextEditingValue insertMarkdownLink(TextEditingValue value) {
  final selection = value.selection;
  final text = value.text;
  final selected = selection.textInside(text);
  final before = selection.textBefore(text);
  final after = selection.textAfter(text);

  final linkText = selected.isEmpty ? 'title' : selected;
  const placeholderUrl = 'url';
  final newText = '$before[$linkText]($placeholderUrl)$after';
  final placeholderStart = selected.isEmpty
      // '[' + 'title'.length selects 'title' itself instead of the url.
      ? before.length + 1
      : before.length + 1 + linkText.length + 2;
  final placeholderLength = selected.isEmpty
      ? linkText.length
      : placeholderUrl.length;
  return TextEditingValue(
    text: newText,
    selection: TextSelection(
      baseOffset: placeholderStart,
      extentOffset: placeholderStart + placeholderLength,
    ),
  );
}

/// Toggles [prefix] (e.g. `# ` for a heading, `- ` for a list item) at the
/// start of the line containing the selection's start in [value]. Adds it
/// if absent, removes it if already present. The cursor is shifted by the
/// same delta as the line, so typing continues naturally.
TextEditingValue toggleLinePrefix(TextEditingValue value, String prefix) {
  final text = value.text;
  final cursor = value.selection.baseOffset;
  // String.lastIndexOf throws on a negative start index, which a cursor
  // at position 0 (searching from cursor - 1) would otherwise trigger.
  final searchFrom = cursor - 1;
  final lineStart = searchFrom < 0 ? 0 : text.lastIndexOf('\n', searchFrom) + 1;
  var lineEnd = text.indexOf('\n', lineStart);
  if (lineEnd == -1) lineEnd = text.length;
  final line = text.substring(lineStart, lineEnd);

  final String newLine;
  final int delta;
  if (line.startsWith(prefix)) {
    newLine = line.substring(prefix.length);
    delta = -prefix.length;
  } else {
    newLine = '$prefix$line';
    delta = prefix.length;
  }

  final newText = text.replaceRange(lineStart, lineEnd, newLine);
  return TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: cursor + delta),
  );
}
