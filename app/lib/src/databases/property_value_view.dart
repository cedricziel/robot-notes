import 'package:flutter/material.dart';

import '../format/note_time.dart';

/// Read-only rendering of a property or built-in field's value: used for
/// built-in columns (`tags`, `created_at`, `updated_at`, `path`), which the
/// spec says are never editable, and for any value a [PropertyEditor]
/// cannot represent (an undeclared property, or a declared one whose
/// stored value doesn't match its type).
///
/// One constructor per built-in shape plus a generic fallback so callers
/// don't have to duplicate the formatting rules themselves.
class PropertyValueView extends StatelessWidget {
  /// Renders [tags] as a row of small chips. An empty list renders nothing
  /// visible but keeps its place in a table row via a zero-size box.
  const PropertyValueView.tags(this._tags, {super.key})
    : _kind = _Kind.tags,
      _timestamp = null,
      _text = null,
      _value = null;

  /// Renders [timestamp] as relative time (e.g. "3 hours ago") with the
  /// absolute timestamp available on hover via a [Tooltip].
  const PropertyValueView.relativeTime(DateTime timestamp, {super.key})
    : _kind = _Kind.relativeTime,
      _timestamp = timestamp,
      _tags = const <String>[],
      _text = null,
      _value = null;

  /// Renders [path] as plain text.
  const PropertyValueView.path(String path, {super.key})
    : _kind = _Kind.text,
      _text = path,
      _tags = const <String>[],
      _timestamp = null,
      _value = null;

  /// Renders an arbitrary [value] the editor for [type] cannot represent
  /// (wrong shape for the declared type, or an undeclared property) as
  /// read-only text — a best-effort `toString`, with `null` shown as an
  /// em dash.
  const PropertyValueView.unrepresentable(Object? value, {super.key})
    : _kind = _Kind.value,
      _value = value,
      _tags = const <String>[],
      _timestamp = null,
      _text = null;

  final _Kind _kind;
  final List<String> _tags;
  final DateTime? _timestamp;
  final String? _text;
  final Object? _value;

  @override
  Widget build(BuildContext context) {
    switch (_kind) {
      case _Kind.tags:
        if (_tags.isEmpty) return const SizedBox.shrink();
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final tag in _tags)
              Chip(
                key: Key('property_value_view.tag.$tag'),
                label: Text(tag),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        );
      case _Kind.relativeTime:
        final ts = _timestamp!;
        return Tooltip(
          message: formatNoteTimestamp(ts),
          child: Text(
            formatRelativeNoteTime(ts),
            key: const Key('property_value_view.relative_time'),
          ),
        );
      case _Kind.text:
        return Text(_text ?? '', key: const Key('property_value_view.text'));
      case _Kind.value:
        return Text(
          _describe(_value),
          key: const Key('property_value_view.unrepresentable'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
    }
  }

  static String _describe(Object? value) {
    if (value == null) return '—';
    if (value is List) return value.join(', ');
    if (value is Map) return value.toString();
    return '$value';
  }
}

enum _Kind { tags, relativeTime, text, value }
