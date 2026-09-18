import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'title_search_service.dart';

/// Commits [patch] for the property this editor is showing (a `set` with
/// the new value, or an `unset` when the user cleared it) and reports the
/// result: `null` on success, or the server's message when the commit was
/// rejected (a `validation_failed` 400) so the editor can revert and show
/// it inline. The caller — the table cell, board card, or property panel —
/// owns the actual `PATCH /notes/{id}/properties` call; see design.md's
/// "Cell editors are one widget family `PropertyEditor(type, value,
/// onCommit)`".
typedef PropertyCommitCallback = Future<String?> Function(PropertyPatch patch);

/// One widget family covering every [PropertyType]'s editor: a plain
/// `TextField` for `text`/`url`, a numeric field for `number`, a `Checkbox`
/// for `checkbox`, a date picker for `date`, a dropdown for `select`, filter
/// chips for `multi_select`, and a title-search picker producing a
/// multi-value list for `relation`.
///
/// Optimistically shows the committed value immediately; if [onCommit]
/// resolves with a non-null message (a `validation_failed` rejection), the
/// editor reverts to the previous value and shows the message inline in
/// error styling. [invalid] additionally applies that styling up front, for
/// a value the server already reported as invalid (a table cell backed by
/// `DatabaseRow.invalid`) — independent of any local commit error.
class PropertyEditor extends StatefulWidget {
  const PropertyEditor({
    required this.propertyKey,
    required this.definition,
    required this.value,
    required this.onCommit,
    this.titleSearchService,
    this.invalid = false,
    super.key,
  });

  /// The property's key, e.g. `status` — used to build the `set` map
  /// (`{propertyKey: newValue}`) sent to [onCommit].
  final String propertyKey;

  final PropertyDefinition definition;
  final Object? value;
  final PropertyCommitCallback onCommit;

  /// Backs the `relation` picker's title search. Required for that type;
  /// unused otherwise. When the definition declares a target [database],
  /// callers should pass a service built with
  /// `TitleSearchService.forDatabase` so suggestions are restricted to that
  /// database's rows, per the "Table cells are editable inline" spec.
  final TitleSearchService? titleSearchService;

  final bool invalid;

  @override
  State<PropertyEditor> createState() => _PropertyEditorState();
}

class _PropertyEditorState extends State<PropertyEditor> {
  late Object? _value = widget.value;
  String? _error;
  String? _localError;
  bool _committing = false;

  @override
  void didUpdateWidget(covariant PropertyEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new value from outside (a re-query, a live update) while nothing is
    // in flight here replaces the local echo; a commit already in progress
    // keeps its own optimistic value until it resolves.
    if (!_committing && oldWidget.value != widget.value) {
      _value = widget.value;
    }
  }

  Future<void> _commit(PropertyPatch patch, Object? optimistic) async {
    final previous = _value;
    setState(() {
      _value = optimistic;
      _error = null;
      _localError = null;
      _committing = true;
    });
    final message = await widget.onCommit(patch);
    if (!mounted) return;
    setState(() {
      _committing = false;
      if (message != null) {
        _value = previous;
        _error = message;
      } else {
        _error = null;
      }
    });
  }

  bool get _showsError => _error != null || _localError != null;

  @override
  Widget build(BuildContext context) {
    final field = switch (widget.definition.type) {
      PropertyType.text => _buildText(isUrl: false),
      PropertyType.url => _buildText(isUrl: true),
      PropertyType.number => _buildNumber(),
      PropertyType.checkbox => _buildCheckbox(),
      PropertyType.date => _buildDate(context),
      PropertyType.select => _buildSelect(),
      PropertyType.multiSelect => _buildMultiSelect(),
      PropertyType.relation => _buildRelation(),
    };
    final showError = widget.invalid || _showsError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: showError
              ? BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.error,
                  ),
                  borderRadius: BorderRadius.circular(4),
                )
              : const BoxDecoration(),
          child: Padding(
            padding: showError ? const EdgeInsets.all(2) : EdgeInsets.zero,
            child: field,
          ),
        ),
        if (_error != null || _localError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _error ?? _localError!,
              key: const Key('property_editor.error'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  // -- text / url --------------------------------------------------------

  Widget _buildText({required bool isUrl}) {
    final text = (_value as String?) ?? '';
    return TextField(
      key: Key(
        isUrl ? 'property_editor.url.field' : 'property_editor.text.field',
      ),
      controller: TextEditingController(text: text)
        ..selection = TextSelection.collapsed(offset: text.length),
      keyboardType: isUrl ? TextInputType.url : TextInputType.text,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onSubmitted: (v) {
        final trimmed = v.trim();
        if (trimmed.isEmpty) {
          unawaited(_commit(PropertyPatch(unset: [widget.propertyKey]), null));
        } else {
          unawaited(
            _commit(PropertyPatch(set: {widget.propertyKey: trimmed}), trimmed),
          );
        }
      },
    );
  }

  // -- number --------------------------------------------------------------

  Widget _buildNumber() {
    final text = _value == null ? '' : '$_value';
    return TextField(
      key: const Key('property_editor.number.field'),
      controller: TextEditingController(text: text)
        ..selection = TextSelection.collapsed(offset: text.length),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onSubmitted: (v) {
        final trimmed = v.trim();
        if (trimmed.isEmpty) {
          unawaited(_commit(PropertyPatch(unset: [widget.propertyKey]), null));
          return;
        }
        final parsed = num.tryParse(trimmed);
        if (parsed == null) {
          setState(() => _localError = 'Enter a valid number.');
          return;
        }
        unawaited(
          _commit(PropertyPatch(set: {widget.propertyKey: parsed}), parsed),
        );
      },
    );
  }

  // -- checkbox --------------------------------------------------------------

  Widget _buildCheckbox() {
    final checked = _value == true;
    return Checkbox(
      key: const Key('property_editor.checkbox'),
      value: checked,
      onChanged: (v) => unawaited(
        _commit(
          PropertyPatch(set: {widget.propertyKey: v ?? false}),
          v ?? false,
        ),
      ),
    );
  }

  // -- date --------------------------------------------------------------

  Widget _buildDate(BuildContext context) {
    final raw = _value as String?;
    final label = raw ?? 'No date';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          key: const Key('property_editor.date.field'),
          onPressed: () async {
            final now = DateTime.now();
            final initial = raw != null ? DateTime.tryParse(raw) : null;
            final picked = await showDatePicker(
              context: context,
              initialDate: initial ?? now,
              firstDate: DateTime(now.year - 100),
              lastDate: DateTime(now.year + 100),
            );
            if (picked == null) return;
            final iso =
                '${picked.year.toString().padLeft(4, '0')}-'
                '${picked.month.toString().padLeft(2, '0')}-'
                '${picked.day.toString().padLeft(2, '0')}';
            await _commit(PropertyPatch(set: {widget.propertyKey: iso}), iso);
          },
          child: Text(label),
        ),
        if (raw != null)
          IconButton(
            key: const Key('property_editor.date.clear'),
            icon: const Icon(Icons.clear, size: 16),
            tooltip: 'Clear',
            onPressed: () => unawaited(
              _commit(PropertyPatch(unset: [widget.propertyKey]), null),
            ),
          ),
      ],
    );
  }

  // -- select --------------------------------------------------------------

  Widget _buildSelect() {
    final options = widget.definition.options ?? const <String>[];
    final raw = _value as String?;
    // An out-of-vocabulary value (an already-invalid cell) can't be
    // selected in the dropdown itself — DropdownButton requires `value` to
    // match exactly one item or be null — so it shows as unset there; the
    // invalid styling around the field is what actually flags the problem.
    final current = raw != null && options.contains(raw) ? raw : null;
    return DropdownButton<String?>(
      key: const Key('property_editor.select'),
      value: current,
      hint: const Text('None'),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('None')),
        for (final option in options)
          DropdownMenuItem<String?>(value: option, child: Text(option)),
      ],
      onChanged: (v) {
        if (v == null) {
          unawaited(_commit(PropertyPatch(unset: [widget.propertyKey]), null));
        } else {
          unawaited(_commit(PropertyPatch(set: {widget.propertyKey: v}), v));
        }
      },
    );
  }

  // -- multi_select --------------------------------------------------------

  Widget _buildMultiSelect() {
    final selected = ((_value as List?) ?? const <Object?>[])
        .map((e) => e as String)
        .toSet();
    final options = widget.definition.options ?? const <String>[];
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final option in options)
          FilterChip(
            key: Key('property_editor.multi_select.chip.$option'),
            label: Text(option),
            selected: selected.contains(option),
            onSelected: (isSelected) {
              final next = {...selected};
              if (isSelected) {
                next.add(option);
              } else {
                next.remove(option);
              }
              final list = next.toList();
              if (list.isEmpty) {
                unawaited(
                  _commit(PropertyPatch(unset: [widget.propertyKey]), null),
                );
              } else {
                unawaited(
                  _commit(PropertyPatch(set: {widget.propertyKey: list}), list),
                );
              }
            },
          ),
      ],
    );
  }

  // -- relation --------------------------------------------------------------

  Widget _buildRelation() {
    final selected = ((_value as List?) ?? const <Object?>[])
        .map((e) => e as String)
        .toList();
    return _RelationEditor(
      selected: selected,
      titleSearchService: widget.titleSearchService,
      onChanged: (titles) {
        if (titles.isEmpty) {
          unawaited(_commit(PropertyPatch(unset: [widget.propertyKey]), null));
        } else {
          unawaited(
            _commit(PropertyPatch(set: {widget.propertyKey: titles}), titles),
          );
        }
      },
    );
  }
}

/// The `relation` type's editor: chips for the selected titles (each
/// removable) plus a search field, backed by [titleSearchService], that
/// adds a title on selection. Always produces a list value, per the "A
/// relation cell SHALL always produce a list value" requirement.
class _RelationEditor extends StatefulWidget {
  const _RelationEditor({
    required this.selected,
    required this.onChanged,
    this.titleSearchService,
  });

  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final TitleSearchService? titleSearchService;

  @override
  State<_RelationEditor> createState() => _RelationEditorState();
}

class _RelationEditorState extends State<_RelationEditor> {
  List<String> _suggestions = const [];
  int _gen = 0;

  Future<void> _search(String query) async {
    final gen = ++_gen;
    final service = widget.titleSearchService;
    if (service == null) return;
    final results = await service.search(query);
    if (!mounted || gen != _gen) return;
    setState(() {
      _suggestions = results
          .where((t) => !widget.selected.contains(t))
          .toList();
    });
  }

  void _add(String title) {
    widget.onChanged([...widget.selected, title]);
    setState(() => _suggestions = const []);
  }

  void _remove(String title) {
    widget.onChanged(widget.selected.where((t) => t != title).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final title in widget.selected)
              InputChip(
                key: Key('property_editor.relation.chip.$title'),
                label: Text(title),
                onDeleted: () => _remove(title),
                deleteButtonTooltipMessage: 'Remove $title',
              ),
          ],
        ),
        TextField(
          key: const Key('property_editor.relation.input'),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            hintText: 'Add...',
          ),
          onChanged: (v) => unawaited(_search(v)),
        ),
        for (final suggestion in _suggestions)
          InkWell(
            key: Key('property_editor.relation.suggestion.$suggestion'),
            onTap: () => _add(suggestion),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(suggestion),
            ),
          ),
      ],
    );
  }
}
