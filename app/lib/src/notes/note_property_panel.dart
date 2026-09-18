import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../databases/property_editor.dart';
import '../databases/property_value_view.dart';
import '../databases/title_search_service.dart';
import 'property_panel_prefs.dart';

/// Commits a property edit for [key] (the map [NoteController.patchProperty]
/// takes has been narrowed to a single key here since each row edits one
/// property at a time), reporting the server's rejection message (or
/// `null` on success) so [PropertyEditor] can revert and show it inline —
/// same contract as `PropertyCommitCallback`, just keyed.
typedef NotePropertyCommit =
    Future<String?> Function(String key, PropertyPatch patch);

/// The note view's property panel (design.md: "Property panel lives in
/// `NoteController`" — this widget is purely presentational over that
/// state). Shown above the note body: declared properties (from every
/// database whose source covers this note, deduplicated in the order the
/// covering definitions are given) get a typed [PropertyEditor], in
/// definition order; every other key in [properties] renders as a
/// read-only key/value row. Collapsible, with the collapsed state
/// persisted per device via [prefs].
///
/// Edits call [onCommit], which the caller wires straight to
/// `NoteController.patchProperty` — this widget never touches the note's
/// title or content edit buffers.
class NotePropertyPanel extends StatefulWidget {
  const NotePropertyPanel({
    required this.properties,
    required this.coveringDefinitions,
    required this.onCommit,
    this.api,
    this.prefs = const SharedPreferencesPropertyPanelPrefs(),
    super.key,
  });

  /// The note's current `properties`, from [NoteState.properties].
  final Map<String, Object?> properties;

  /// The registered databases whose source covers this note, from
  /// [NoteState.coveringDefinitions].
  final List<DatabaseDefinition> coveringDefinitions;

  final NotePropertyCommit onCommit;

  /// Backs `relation` property pickers' title search, restricted to their
  /// declared target database. `null` disables relation search (the field
  /// still renders, with no suggestions).
  final RobotNotesClient? api;

  final PropertyPanelPrefs prefs;

  @override
  State<NotePropertyPanel> createState() => _NotePropertyPanelState();
}

class _NotePropertyPanelState extends State<NotePropertyPanel> {
  bool _collapsed = false;

  // Set as soon as the user toggles the panel, so a slower in-flight
  // [_loadCollapsed] read can't land afterward and stomp the toggle with
  // the stale stored value.
  bool _collapsedChanged = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCollapsed());
  }

  Future<void> _loadCollapsed() async {
    final collapsed = await widget.prefs.readCollapsed();
    if (!mounted || _collapsedChanged) return;
    setState(() => _collapsed = collapsed);
  }

  void _toggle() {
    final next = !_collapsed;
    setState(() {
      _collapsedChanged = true;
      _collapsed = next;
    });
    unawaited(widget.prefs.writeCollapsed(next));
  }

  /// Declared property keys with their [PropertyDefinition], in the order
  /// [DatabaseDefinition.properties] declares them, walking
  /// [NotePropertyPanel.coveringDefinitions] in order and skipping a key
  /// already seen from an earlier-covering definition.
  List<MapEntry<String, PropertyDefinition>> _declared() {
    final seen = <String>{};
    final result = <MapEntry<String, PropertyDefinition>>[];
    for (final def in widget.coveringDefinitions) {
      for (final entry in def.properties.entries) {
        if (seen.add(entry.key)) result.add(entry);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final declared = _declared();
    final declaredKeys = declared.map((e) => e.key).toSet();
    final undeclared = widget.properties.entries
        .where((e) => !declaredKeys.contains(e.key))
        .toList(growable: false);
    if (declared.isEmpty && undeclared.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Card(
      key: const Key('note.propertyPanel'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: const Key('note.propertyPanel.toggle'),
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                  Text('Properties', style: theme.textTheme.labelLarge),
                ],
              ),
            ),
          ),
          if (!_collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in declared)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _DeclaredRow(
                        propertyKey: entry.key,
                        definition: entry.value,
                        value: widget.properties[entry.key],
                        api: widget.api,
                        onCommit: (patch) => widget.onCommit(entry.key, patch),
                      ),
                    ),
                  for (final entry in undeclared)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _UndeclaredRow(
                        propertyKey: entry.key,
                        value: entry.value,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DeclaredRow extends StatelessWidget {
  const _DeclaredRow({
    required this.propertyKey,
    required this.definition,
    required this.value,
    required this.onCommit,
    this.api,
  });

  final String propertyKey;
  final PropertyDefinition definition;
  final Object? value;
  final PropertyCommitCallback onCommit;
  final RobotNotesClient? api;

  @override
  Widget build(BuildContext context) {
    TitleSearchService? titleSearchService;
    final apiClient = api;
    if (definition.type == PropertyType.relation && apiClient != null) {
      final target = definition.database;
      titleSearchService = target != null
          ? TitleSearchService.forDatabase(api: apiClient, databaseId: target)
          : TitleSearchService(api: apiClient);
    }
    return Column(
      key: Key('note.propertyPanel.property.$propertyKey'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          definition.label ?? propertyKey,
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 2),
        PropertyEditor(
          propertyKey: propertyKey,
          definition: definition,
          value: value,
          titleSearchService: titleSearchService,
          onCommit: onCommit,
        ),
      ],
    );
  }
}

class _UndeclaredRow extends StatelessWidget {
  const _UndeclaredRow({required this.propertyKey, required this.value});

  final String propertyKey;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key('note.propertyPanel.undeclared.$propertyKey'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            propertyKey,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        Expanded(child: PropertyValueView.unrepresentable(value)),
      ],
    );
  }
}
