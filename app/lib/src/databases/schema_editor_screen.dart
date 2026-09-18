import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';

/// The property key rule the spec requires client-side, before
/// `PUT /databases/{id}` is even attempted: `^[a-z][a-z0-9_]*$`.
final RegExp propertyKeyPattern = RegExp(r'^[a-z][a-z0-9_]*$');

/// A full-screen form editing a [DatabaseDefinition]'s `properties` and
/// `views`, per design.md's "Schema editor is a full-screen form" — tasks
/// 6.2 (properties CRUD) and 6.3 (views CRUD) of `add-database-views`.
///
/// Holds a local mutable draft seeded from [definition]; nothing is sent
/// until "Save", which issues `PUT /databases/{id}` with the whole
/// `properties`/`views` sections and `If-Match: <version>`. A 409
/// (`VersionConflictException`, whose body carries no `current` note for
/// this endpoint) reloads the definition via `GET /databases/{id}` to pick
/// up the new version, but keeps every local edit exactly as the user left
/// it so they can hit Save again.
class SchemaEditorScreen extends StatefulWidget {
  const SchemaEditorScreen({
    required this.definition,
    required this.api,
    required this.onSaved,
    this.onClose,
    super.key,
  });

  final DatabaseDefinition definition;
  final RobotNotesClient api;

  /// Called with the server's response once a save succeeds.
  final ValueChanged<DatabaseDefinition> onSaved;
  final VoidCallback? onClose;

  @override
  State<SchemaEditorScreen> createState() => _SchemaEditorScreenState();
}

class _SchemaEditorScreenState extends State<SchemaEditorScreen> {
  late int _baseVersion = widget.definition.version;
  late final List<_PropertyRow> _properties = [
    for (final entry in widget.definition.properties.entries)
      _PropertyRow.from(entry.key, entry.value),
  ];
  late final List<_ViewRow> _views = [
    for (final v in widget.definition.views) _ViewRow.from(v),
  ];

  bool _saving = false;
  String? _error;
  String? _conflictNotice;
  int _rowSeq = 0;

  bool get _keysValid {
    final seen = <String>{};
    for (final p in _properties) {
      final key = p.keyController.text.trim();
      if (!propertyKeyPattern.hasMatch(key)) return false;
      if (!seen.add(key)) return false;
    }
    return true;
  }

  void _addProperty() {
    setState(() {
      _properties.add(
        _PropertyRow(
          id: _rowSeq++,
          keyController: TextEditingController(),
          labelController: TextEditingController(),
          type: PropertyType.text,
          optionsController: TextEditingController(),
          databaseController: TextEditingController(),
        ),
      );
    });
  }

  void _removeProperty(_PropertyRow row) {
    setState(() => _properties.remove(row));
  }

  void _addView() {
    setState(() {
      _views.add(
        _ViewRow(
          id: _rowSeq++,
          nameController: TextEditingController(
            text: 'View ${_views.length + 1}',
          ),
          type: ViewType.table,
          groupByController: TextEditingController(),
          sortPropertyController: TextEditingController(),
          sortDirection: SortDirection.asc,
          propertiesController: TextEditingController(),
          conditions: [],
          combinator: _Combinator.and,
        ),
      );
    });
  }

  void _removeView(_ViewRow row) {
    setState(() => _views.remove(row));
  }

  void _moveView(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _views.length) return;
    setState(() {
      final row = _views.removeAt(index);
      _views.insert(target, row);
    });
  }

  Map<String, PropertyDefinition> _buildProperties() => {
    for (final p in _properties) p.keyController.text.trim(): p.toDefinition(),
  };

  List<ViewDefinition> _buildViews() => [
    for (final v in _views) v.toDefinition(),
  ];

  Future<void> _save() async {
    if (!_keysValid || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await widget.api.updateDatabase(
        id: widget.definition.id,
        ifMatch: _baseVersion,
        properties: _buildProperties(),
        views: _buildViews(),
      );
      if (!mounted) return;
      widget.onSaved(updated);
    } on VersionConflictException catch (e) {
      if (!mounted) return;
      try {
        final fresh = await widget.api.getDatabase(widget.definition.id);
        if (!mounted) return;
        setState(() {
          _baseVersion = fresh.version;
          _conflictNotice =
              'Someone else changed this database (now at version '
              '${fresh.version}). Your edits are still here — save again to '
              'apply them.';
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _error = e.message ?? 'Version conflict. Please reload and retry.';
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message ?? 'Could not save this database.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit schema'),
        leading: IconButton(
          key: const Key('schemaEditor.close'),
          icon: const Icon(Icons.close),
          onPressed: _close,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton(
              key: const Key('schemaEditor.save'),
              onPressed: _keysValid && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            _Banner(
              key: const Key('schemaEditor.error'),
              message: _error!,
              color: Theme.of(context).colorScheme.errorContainer,
            ),
          if (_conflictNotice != null)
            _Banner(
              key: const Key('schemaEditor.conflict'),
              message: _conflictNotice!,
              color: Theme.of(context).colorScheme.secondaryContainer,
            ),
          Text('Properties', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final row in _properties)
            _PropertyEditorRow(
              key: ValueKey<int>(row.id),
              row: row,
              onChanged: () => setState(() {}),
              onRemove: () => _removeProperty(row),
            ),
          TextButton.icon(
            key: const Key('schemaEditor.addProperty'),
            onPressed: _addProperty,
            icon: const Icon(Icons.add),
            label: const Text('Add property'),
          ),
          const Divider(height: 32),
          Text('Views', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (var i = 0; i < _views.length; i++)
            _ViewEditorRow(
              key: ValueKey<int>(_views[i].id),
              row: _views[i],
              index: i,
              last: i == _views.length - 1,
              availableProperties: [
                for (final p in _properties) p.keyController.text,
              ],
              onChanged: () => setState(() {}),
              onRemove: () => _removeView(_views[i]),
              onMoveUp: () => _moveView(i, -1),
              onMoveDown: () => _moveView(i, 1),
            ),
          TextButton.icon(
            key: const Key('schemaEditor.addView'),
            onPressed: _addView,
            icon: const Icon(Icons.add),
            label: const Text('Add view'),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.color, super.key});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(message),
    );
  }
}

/// A mutable draft of one [PropertyDefinition], keyed by a stable local
/// [id] independent of the (editable) property key text.
class _PropertyRow {
  _PropertyRow({
    required this.id,
    required this.keyController,
    required this.labelController,
    required this.type,
    required this.optionsController,
    required this.databaseController,
  });

  factory _PropertyRow.from(String key, PropertyDefinition def) => _PropertyRow(
    id: key.hashCode ^ DateTime.now().microsecondsSinceEpoch,
    keyController: TextEditingController(text: key),
    labelController: TextEditingController(text: def.label ?? ''),
    type: def.type,
    optionsController: TextEditingController(
      text: (def.options ?? const <String>[]).join(', '),
    ),
    databaseController: TextEditingController(text: def.database ?? ''),
  );

  final int id;
  final TextEditingController keyController;
  final TextEditingController labelController;
  PropertyType type;
  final TextEditingController optionsController;
  final TextEditingController databaseController;

  bool get needsOptions =>
      type == PropertyType.select || type == PropertyType.multiSelect;

  PropertyDefinition toDefinition() => PropertyDefinition(
    type: type,
    label: labelController.text.trim().isEmpty
        ? null
        : labelController.text.trim(),
    options: needsOptions
        ? optionsController.text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList()
        : null,
    database:
        type == PropertyType.relation &&
            databaseController.text.trim().isNotEmpty
        ? databaseController.text.trim()
        : null,
  );
}

class _PropertyEditorRow extends StatelessWidget {
  const _PropertyEditorRow({
    required this.row,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  final _PropertyRow row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final key = row.keyController.text.trim();
    final keyValid = propertyKeyPattern.hasMatch(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: Key('schemaEditor.property.${row.id}.key'),
                      controller: row.keyController,
                      decoration: InputDecoration(
                        labelText: 'Key',
                        errorText: keyValid || key.isEmpty
                            ? null
                            : 'Must match ^[a-z][a-z0-9_]*\$',
                      ),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      key: Key('schemaEditor.property.${row.id}.label'),
                      controller: row.labelController,
                      decoration: const InputDecoration(labelText: 'Label'),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<PropertyType>(
                    key: Key('schemaEditor.property.${row.id}.type'),
                    value: row.type,
                    items: [
                      for (final t in PropertyType.values)
                        DropdownMenuItem(value: t, child: Text(t.wire)),
                    ],
                    onChanged: (t) {
                      if (t != null) row.type = t;
                      onChanged();
                    },
                  ),
                  IconButton(
                    key: Key('schemaEditor.property.${row.id}.remove'),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove — row values stay on disk but are hidden',
                    onPressed: onRemove,
                  ),
                ],
              ),
              if (row.needsOptions)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextFormField(
                    key: Key('schemaEditor.property.${row.id}.options'),
                    controller: row.optionsController,
                    decoration: const InputDecoration(
                      labelText: 'Options (comma-separated)',
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              if (row.type == PropertyType.relation)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextFormField(
                    key: Key('schemaEditor.property.${row.id}.database'),
                    controller: row.databaseController,
                    decoration: const InputDecoration(
                      labelText: 'Target database id (optional)',
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Combinator { and, or }

/// A single filter condition row: `{property, op, value?}`.
class _ConditionRow {
  _ConditionRow({
    required this.propertyController,
    required this.op,
    required this.valueController,
  });

  factory _ConditionRow.empty() => _ConditionRow(
    propertyController: TextEditingController(),
    op: FilterOp.eq,
    valueController: TextEditingController(),
  );

  factory _ConditionRow.from(Condition c) => _ConditionRow(
    propertyController: TextEditingController(text: c.property),
    op: c.op,
    valueController: TextEditingController(
      text: c.value == null ? '' : '${c.value}',
    ),
  );

  final TextEditingController propertyController;
  FilterOp op;
  final TextEditingController valueController;

  Condition toCondition() => Condition(
    property: propertyController.text.trim(),
    op: op,
    value: (op == FilterOp.isEmpty || op == FilterOp.isNotEmpty)
        ? null
        : valueController.text,
  );
}

/// A mutable draft of one [ViewDefinition]. Supports one level of filter
/// nesting (a flat list of [_ConditionRow]s joined by a single and/or
/// [combinator]), matching design.md's "one level of nesting supported in
/// the UI" — deeper filters set through other means round-trip untouched
/// only if never edited here; this editor always rewrites `filter` from
/// its flat condition list.
class _ViewRow {
  _ViewRow({
    required this.id,
    required this.nameController,
    required this.type,
    required this.groupByController,
    required this.sortPropertyController,
    required this.sortDirection,
    required this.propertiesController,
    required this.conditions,
    required this.combinator,
  });

  factory _ViewRow.from(ViewDefinition v) {
    final conditions = <_ConditionRow>[];
    var combinator = _Combinator.and;
    final filter = v.filter;
    if (filter is Condition) {
      conditions.add(_ConditionRow.from(filter));
    } else if (filter is And) {
      combinator = _Combinator.and;
      for (final f in filter.and) {
        if (f is Condition) conditions.add(_ConditionRow.from(f));
      }
    } else if (filter is Or) {
      combinator = _Combinator.or;
      for (final f in filter.or) {
        if (f is Condition) conditions.add(_ConditionRow.from(f));
      }
    }
    final sort = (v.sort ?? const <SortSpec>[]).isEmpty ? null : v.sort!.first;
    return _ViewRow(
      id: v.name.hashCode ^ DateTime.now().microsecondsSinceEpoch,
      nameController: TextEditingController(text: v.name),
      type: v.type,
      groupByController: TextEditingController(text: v.groupBy ?? ''),
      sortPropertyController: TextEditingController(text: sort?.property ?? ''),
      sortDirection: sort?.direction ?? SortDirection.asc,
      propertiesController: TextEditingController(
        text: (v.properties ?? const <String>[]).join(', '),
      ),
      conditions: conditions,
      combinator: combinator,
    );
  }

  final int id;
  final TextEditingController nameController;
  ViewType type;
  final TextEditingController groupByController;
  final TextEditingController sortPropertyController;
  SortDirection sortDirection;
  final TextEditingController propertiesController;
  final List<_ConditionRow> conditions;
  _Combinator combinator;

  Filter? _buildFilter() {
    if (conditions.isEmpty) return null;
    final built = [
      for (final c in conditions)
        if (c.propertyController.text.trim().isNotEmpty) c.toCondition(),
    ];
    if (built.isEmpty) return null;
    if (built.length == 1) return built.first;
    return combinator == _Combinator.and ? And(built) : Or(built);
  }

  ViewDefinition toDefinition() {
    final sortProperty = sortPropertyController.text.trim();
    final properties = propertiesController.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return ViewDefinition(
      name: nameController.text.trim(),
      type: type,
      filter: _buildFilter(),
      sort: sortProperty.isEmpty
          ? null
          : [SortSpec(property: sortProperty, direction: sortDirection)],
      groupBy:
          type == ViewType.board && groupByController.text.trim().isNotEmpty
          ? groupByController.text.trim()
          : null,
      properties: properties.isEmpty ? null : properties,
    );
  }
}

class _ViewEditorRow extends StatelessWidget {
  const _ViewEditorRow({
    required this.row,
    required this.index,
    required this.last,
    required this.availableProperties,
    required this.onChanged,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
    super.key,
  });

  final _ViewRow row;
  final int index;
  final bool last;
  final List<String> availableProperties;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: Key('schemaEditor.view.${row.id}.name'),
                      controller: row.nameController,
                      decoration: const InputDecoration(labelText: 'Name'),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<ViewType>(
                    key: Key('schemaEditor.view.${row.id}.type'),
                    value: row.type,
                    items: [
                      for (final t in ViewType.values)
                        DropdownMenuItem(value: t, child: Text(t.wire)),
                    ],
                    onChanged: (t) {
                      if (t != null) row.type = t;
                      onChanged();
                    },
                  ),
                  IconButton(
                    key: Key('schemaEditor.view.${row.id}.up'),
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: index == 0 ? null : onMoveUp,
                  ),
                  IconButton(
                    key: Key('schemaEditor.view.${row.id}.down'),
                    icon: const Icon(Icons.arrow_downward),
                    onPressed: last ? null : onMoveDown,
                  ),
                  IconButton(
                    key: Key('schemaEditor.view.${row.id}.remove'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onRemove,
                  ),
                ],
              ),
              if (row.type == ViewType.board)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextFormField(
                    key: Key('schemaEditor.view.${row.id}.groupBy'),
                    controller: row.groupByController,
                    decoration: const InputDecoration(labelText: 'Group by'),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextFormField(
                  key: Key('schemaEditor.view.${row.id}.properties'),
                  controller: row.propertiesController,
                  decoration: const InputDecoration(
                    labelText: 'Visible properties (comma-separated)',
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: Key('schemaEditor.view.${row.id}.sortProperty'),
                        controller: row.sortPropertyController,
                        decoration: const InputDecoration(labelText: 'Sort by'),
                        onChanged: (_) => onChanged(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<SortDirection>(
                      key: Key('schemaEditor.view.${row.id}.sortDirection'),
                      value: row.sortDirection,
                      items: const [
                        DropdownMenuItem(
                          value: SortDirection.asc,
                          child: Text('asc'),
                        ),
                        DropdownMenuItem(
                          value: SortDirection.desc,
                          child: Text('desc'),
                        ),
                      ],
                      onChanged: (d) {
                        if (d != null) row.sortDirection = d;
                        onChanged();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text('Filter', style: Theme.of(context).textTheme.labelLarge),
              if (row.conditions.length > 1)
                Row(
                  children: [
                    const Text('Combine with:'),
                    const SizedBox(width: 8),
                    DropdownButton<_Combinator>(
                      key: Key('schemaEditor.view.${row.id}.combinator'),
                      value: row.combinator,
                      items: const [
                        DropdownMenuItem(
                          value: _Combinator.and,
                          child: Text('and'),
                        ),
                        DropdownMenuItem(
                          value: _Combinator.or,
                          child: Text('or'),
                        ),
                      ],
                      onChanged: (c) {
                        if (c != null) row.combinator = c;
                        onChanged();
                      },
                    ),
                  ],
                ),
              for (var i = 0; i < row.conditions.length; i++)
                _ConditionEditorRow(
                  key: ValueKey<TextEditingController>(
                    row.conditions[i].propertyController,
                  ),
                  viewId: row.id,
                  index: i,
                  condition: row.conditions[i],
                  onChanged: onChanged,
                  onRemove: () {
                    row.conditions.removeAt(i);
                    onChanged();
                  },
                ),
              TextButton.icon(
                key: Key('schemaEditor.view.${row.id}.addCondition'),
                onPressed: () {
                  row.conditions.add(_ConditionRow.empty());
                  onChanged();
                },
                icon: const Icon(Icons.add),
                label: const Text('Add condition'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConditionEditorRow extends StatelessWidget {
  const _ConditionEditorRow({
    required this.viewId,
    required this.index,
    required this.condition,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  final int viewId;
  final int index;
  final _ConditionRow condition;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: TextFormField(
              key: Key('schemaEditor.view.$viewId.condition.$index.property'),
              controller: condition.propertyController,
              decoration: const InputDecoration(labelText: 'Property'),
              onChanged: (_) => onChanged(),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<FilterOp>(
            key: Key('schemaEditor.view.$viewId.condition.$index.op'),
            value: condition.op,
            items: [
              for (final op in FilterOp.values)
                DropdownMenuItem(value: op, child: Text(op.wire)),
            ],
            onChanged: (op) {
              if (op != null) condition.op = op;
              onChanged();
            },
          ),
          const SizedBox(width: 8),
          if (condition.op != FilterOp.isEmpty &&
              condition.op != FilterOp.isNotEmpty)
            Expanded(
              child: TextFormField(
                key: Key('schemaEditor.view.$viewId.condition.$index.value'),
                controller: condition.valueController,
                decoration: const InputDecoration(labelText: 'Value'),
                onChanged: (_) => onChanged(),
              ),
            ),
          IconButton(
            key: Key('schemaEditor.view.$viewId.condition.$index.remove'),
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
