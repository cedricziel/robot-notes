import 'dart:async';

import 'package:adaptive_super_editor/adaptive_super_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:material_ui/material_ui.dart';
import 'package:super_editor/super_editor.dart';

import '../layout/breakpoints.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive.dart';
import '../widgets/platform_motion.dart';
import 'link_autocomplete.dart';

/// Edits one Markdown draft through a persistent document and source controller.
/// Supplied controllers remain owned by the caller. A source builder publishes
/// its own changes to the parent, which supplies the resulting [markdown].
class BlockNoteEditor extends StatefulWidget {
  const BlockNoteEditor({
    required this.markdown,
    required this.onChanged,
    this.readOnly = false,
    this.sourceController,
    this.header,
    this.sourceBuilder,
    this.opaqueBuilder,
    this.searchLinkTitles,
    super.key,
  });

  final String markdown;
  final ValueChanged<String> onChanged;
  final bool readOnly;
  final TextEditingController? sourceController;
  final Widget? header;
  final Widget Function(BuildContext, TextEditingController, bool readOnly)?
  sourceBuilder;
  final Widget Function(BuildContext, String rawSource)? opaqueBuilder;
  final Future<List<String>> Function(String query)? searchLinkTitles;

  @override
  State<BlockNoteEditor> createState() => _BlockNoteEditorState();
}

class _BlockNoteEditorState extends State<BlockNoteEditor> {
  late final MarkdownEditingDocument _draft;
  late final MutableDocumentComposer _composer;
  late final Editor _editor;
  final _focus = FocusNode(debugLabel: 'Block document');
  final _layoutKey = GlobalKey();
  late TextEditingController _source;
  late String _published;
  bool _sourceMode = false;
  bool _replacing = false;
  bool _menuOpen = false;
  String? _slashDismissed;
  DocumentSelection? _blockSelection;
  LinkAutocompleteController? _links;
  String? _linkNode;

  @override
  void initState() {
    super.initState();
    _draft = MarkdownEditingDocument.fromMarkdown(widget.markdown);
    _composer = MutableDocumentComposer();
    _editor = createMarkdownDocumentEditor(
      document: _draft.document,
      composer: _composer,
    );
    _editor.requestHandlers.insert(0, (_, request) {
      if (request is! PasteEditorRequest) return null;
      final fragment = MarkdownEditingDocument.fromMarkdown(request.content);
      _draft.retainSources(fragment);
      return PasteStructuredContentEditorCommand(
        content: fragment.document,
        pastePosition: request.pastePosition,
      );
    });
    _source =
        widget.sourceController ?? TextEditingController(text: widget.markdown);
    _published = widget.markdown;
    _draft.document.addListener(_documentChanged);
    _composer.selectionNotifier.addListener(_selectionChanged);
    _configureLinks();
  }

  void _configureLinks() {
    _links?.removeListener(_linksChanged);
    _links?.dispose();
    _links = widget.searchLinkTitles == null
        ? null
        : LinkAutocompleteController(search: widget.searchLinkTitles!);
    _links?.addListener(_linksChanged);
  }

  @override
  void didUpdateWidget(BlockNoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchLinkTitles != widget.searchLinkTitles) {
      _configureLinks();
    }
    if (oldWidget.sourceController != widget.sourceController) {
      if (oldWidget.sourceController == null) _source.dispose();
      _source =
          widget.sourceController ?? TextEditingController(text: _published);
    }
    if (widget.markdown != oldWidget.markdown &&
        widget.markdown != _published) {
      _published = widget.markdown;
      if (!_sourceMode) {
        _replacing = true;
        _draft.replaceMarkdown(widget.markdown, _editor);
        _replacing = false;
      }
      _setSource(widget.markdown);
    }
    if (widget.readOnly && !oldWidget.readOnly) {
      _links?.close();
      _focus.unfocus();
    }
  }

  @override
  void dispose() {
    _draft.document.removeListener(_documentChanged);
    _composer.selectionNotifier.removeListener(_selectionChanged);
    _links?.removeListener(_linksChanged);
    _links?.dispose();
    if (widget.sourceController == null) _source.dispose();
    _focus.dispose();
    _editor.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _setSource(String value) {
    if (_source.text == value) return;
    _source.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _publish(String value) {
    if (value == _published) return;
    _published = value;
    widget.onChanged(value);
  }

  void _documentChanged(DocumentChangeLog changes) {
    if (_replacing) return;
    _publish(_draft.toMarkdown());
    _selectionChanged();
  }

  void _selectionChanged() {
    if (!mounted || _sourceMode || widget.readOnly) return;
    final selection = _composer.selection;
    final node = selection == null
        ? null
        : _draft.document.getNodeById(selection.extent.nodeId);
    if (selection?.isCollapsed == true &&
        node is TextNode &&
        selection!.extent.nodePosition is TextNodePosition) {
      final offset = (selection.extent.nodePosition as TextNodePosition).offset;
      _linkNode = node.id;
      _links?.onChanged(node.text.toPlainText(), offset);
      if (node is ParagraphNode &&
          node.getMetadataValue('blockType') == paragraphAttribution &&
          node.text.toPlainText() == '/' &&
          offset == 1 &&
          _slashDismissed != node.id &&
          !_menuOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !widget.readOnly && !_sourceMode && !_menuOpen) {
            unawaited(_chooseBlock(node.id, slash: true));
          }
        });
      } else if (node.text.toPlainText() != '/') {
        _slashDismissed = null;
      }
    } else {
      _links?.close();
    }
  }

  void _linksChanged() {
    if (mounted) setState(() {});
  }

  void _switchMode(bool source, {String? nodeId}) {
    if (source == _sourceMode) return;
    _links?.close();
    if (source) {
      _blockSelection = _composer.selection;
      _editor.execute([ChangeComposingRegionRequest(null)]);
      _focus.unfocus();
      _setSource(_draft.toMarkdown());
      if (nodeId != null) {
        final range = _draft.sourceRangeForNode(nodeId);
        _source.selection = TextSelection(
          baseOffset: range.start,
          extentOffset: range.end,
        );
      }
    } else {
      final text = _source.text;
      if (text != _draft.toMarkdown()) {
        _replacing = true;
        _draft.replaceMarkdown(text, _editor);
        _replacing = false;
        _publish(text);
        final selection = _source.selection;
        _blockSelection = DocumentSelection(
          base: _positionForSourceOffset(
            selection.isValid ? selection.baseOffset : 0,
          ),
          extent: _positionForSourceOffset(
            selection.isValid ? selection.extentOffset : 0,
          ),
        );
      }
      if (_blockSelection != null &&
          _draft.document.getNodeById(_blockSelection!.extent.nodeId) != null) {
        _editor.execute([
          ChangeSelectionRequest(
            _blockSelection,
            SelectionChangeType.placeCaret,
            SelectionReason.userInteraction,
          ),
        ]);
      }
    }
    setState(() => _sourceMode = source);
  }

  DocumentPosition _positionForSourceOffset(int offset) {
    for (final node in _draft.document) {
      final range = _draft.sourceRangeForNode(node.id);
      if (offset > range.end && node.id != _draft.document.last.id) continue;
      NodePosition position = node.beginningPosition;
      if (node is TextNode) {
        final text = node.text.toPlainText();
        final source = _draft.sourceForNode(node.id);
        final textStart = source.indexOf(text);
        if (textStart >= 0) {
          position = TextNodePosition(
            offset: (offset - range.start - textStart).clamp(0, text.length),
          );
        }
      }
      return DocumentPosition(nodeId: node.id, nodePosition: position);
    }
    return DocumentPosition(
      nodeId: _draft.document.last.id,
      nodePosition: _draft.document.last.endPosition,
    );
  }

  DocumentNode _makeNode(_BlockKind kind, String id, AttributedText text) {
    return switch (kind) {
      _BlockKind.bullets => ListItemNode(
        id: id,
        text: text,
        itemType: ListItemType.unordered,
      ),
      _BlockKind.numbers => ListItemNode(
        id: id,
        text: text,
        itemType: ListItemType.ordered,
      ),
      _BlockKind.task => TaskNode(id: id, text: text, isComplete: false),
      _BlockKind.divider => HorizontalRuleNode(id: id),
      _ => ParagraphNode(
        id: id,
        text: text,
        metadata: {
          'blockType': switch (kind) {
            _BlockKind.heading1 => header1Attribution,
            _BlockKind.heading2 => header2Attribution,
            _BlockKind.heading3 => header3Attribution,
            _BlockKind.heading4 => header4Attribution,
            _BlockKind.heading5 => header5Attribution,
            _BlockKind.heading6 => header6Attribution,
            _BlockKind.quote => blockquoteAttribution,
            _BlockKind.code => codeAttribution,
            _ => paragraphAttribution,
          },
        },
      ),
    };
  }

  void _selectNode(DocumentNode node, {NodePosition? position}) {
    _editor.execute([
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: node.id,
            nodePosition: position ?? node.beginningPosition,
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
  }

  Future<void> _chooseBlock(
    String? id, {
    bool insert = false,
    bool slash = false,
  }) async {
    if (widget.readOnly || _menuOpen) return;
    final previousSelection = _composer.selection;
    _menuOpen = true;
    final kind = await showPlatformDialog<_BlockKind>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(insert ? 'Insert block' : 'Convert block'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final kind in _BlockKind.values)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(kind),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(kind.label),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          adaptiveDialogAction(
            context,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    _menuOpen = false;
    if (!mounted || widget.readOnly) return;
    if (kind == null) {
      if (slash) _slashDismissed = id;
      return;
    }
    final existing = id == null ? null : _draft.document.getNodeById(id);
    if (!insert && existing is! TextNode) return;
    final text = insert || slash
        ? AttributedText('')
        : (existing as TextNode).text.copy();
    if (kind == _BlockKind.divider && text.isNotEmpty) {
      final confirmed = await showPlatformDialog<bool>(
        context: context,
        builder: (context) => AlertDialog.adaptive(
          title: const Text('Replace text with divider?'),
          content: const Text(
            'This removes the text in this block. You can undo this change.',
          ),
          actions: [
            adaptiveDialogAction(
              context,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            adaptiveDialogAction(
              context,
              onPressed: () => Navigator.of(context).pop(true),
              destructive: true,
              primary: true,
              child: const Text('Replace text'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true || widget.readOnly) return;
    }
    final node = _makeNode(
      kind,
      insert ? Editor.createNodeId() : existing!.id,
      text,
    );
    _editor.execute([
      if (insert)
        InsertNodeAtIndexRequest(
          nodeIndex: existing == null
              ? _draft.document.nodeCount
              : _draft.document.getNodeIndexById(existing.id) + 1,
          newNode: node,
        )
      else
        ReplaceNodeRequest(existingNodeId: existing!.id, newNode: node),
      ChangeSelectionRequest(
        !insert &&
                !slash &&
                kind != _BlockKind.divider &&
                previousSelection?.extent.nodeId == node.id
            ? previousSelection
            : DocumentSelection.collapsed(
                position: DocumentPosition(
                  nodeId: node.id,
                  nodePosition: node.beginningPosition,
                ),
              ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
    _focus.requestFocus();
  }

  void _move(String id, int index) {
    if (widget.readOnly || index < 0 || index >= _draft.document.nodeCount) {
      return;
    }
    final selection = _composer.selection;
    _editor.execute([MoveNodeRequest(nodeId: id, newIndex: index)]);
    if (selection != null && selection.extent.nodeId == id) {
      _editor.execute([
        ChangeSelectionRequest(
          selection,
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
    } else {
      _selectNode(_draft.document.getNodeById(id)!);
    }
    _focus.requestFocus();
  }

  void _delete(String id) {
    if (widget.readOnly) return;
    if (_draft.document.nodeCount == 1) {
      _editor.execute([
        ReplaceNodeWithEmptyParagraphWithCaretRequest(nodeId: id),
      ]);
    } else {
      final index = _draft.document.getNodeIndexById(id);
      final next = _draft.document.getNodeAt(index == 0 ? 1 : index - 1)!;
      _editor.execute([
        DeleteNodeRequest(nodeId: id),
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: next.id,
              nodePosition: next.endPosition,
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
    }
    _focus.requestFocus();
  }

  void _format(Attribution attribution) {
    if (widget.readOnly) return;
    final selection = _composer.selection;
    if (selection == null) return;
    if (selection.isCollapsed) {
      _composer.preferences.toggleStyle(attribution);
    } else {
      _editor.execute([
        ToggleTextAttributionsRequest(
          documentRange: selection,
          attributions: {attribution},
        ),
      ]);
    }
    _focus.requestFocus();
  }

  Future<void> _link() async {
    if (widget.readOnly || _composer.selection == null) return;
    final selection = _composer.selection!;
    var destination = '';
    final result = await showPlatformDialog<String>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Add link'),
        content: AdaptiveDialogTextField(
          label: 'URL',
          hint: 'https://example.com',
          onChanged: (value) => destination = value,
        ),
        actions: [
          adaptiveDialogAction(
            context,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          adaptiveDialogAction(
            context,
            onPressed: () => Navigator.of(context).pop(destination),
            primary: true,
            child: const Text('Add link'),
          ),
        ],
      ),
    );
    if (!mounted ||
        widget.readOnly ||
        result == null ||
        result.trim().isEmpty) {
      return;
    }
    final start = selection.extent;
    final offset = start.nodePosition is TextNodePosition
        ? (start.nodePosition as TextNodePosition).offset
        : null;
    if (selection.isCollapsed && offset == null) return;
    _editor.execute([
      ChangeSelectionRequest(
        selection,
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
      if (selection.isCollapsed) ...[
        InsertTextRequest(
          documentPosition: start,
          textToInsert: result.trim(),
          attributions: {LinkAttribution(result.trim())},
        ),
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: start.nodeId,
              nodePosition: TextNodePosition(
                offset: offset! + result.trim().length,
              ),
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ] else
        AddTextAttributionsRequest(
          documentRange: selection,
          attributions: {LinkAttribution(result.trim())},
        ),
    ]);
    _focus.requestFocus();
  }

  void _insertWikiLink(String title) {
    if (widget.readOnly) return;
    final trigger = _links?.value.trigger;
    final node = _linkNode == null
        ? null
        : _draft.document.getNodeById(_linkNode!);
    if (trigger == null || node is! TextNode) return;
    final insertion = insertLink(node.text.toPlainText(), trigger, title);
    final text = node.text
        .removeRegion(startOffset: trigger.start, endOffset: trigger.end)
        .insertString(
          textToInsert: insertion.text.substring(
            trigger.start,
            insertion.cursor,
          ),
          startOffset: trigger.start,
        );
    text.addAttribution(
      wikiLinkAttribution,
      SpanRange(trigger.start, insertion.cursor - 1),
    );
    _editor.execute([
      ReplaceNodeRequest(
        existingNodeId: node.id,
        newNode: node.copyTextNodeWith(text: text),
      ),
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: insertion.cursor),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
    _links?.close();
    _focus.requestFocus();
  }

  Widget _blockFrame(String id, Widget child, double firstLineCenter) {
    final node = _draft.document.getNodeById(id)!;
    if (node.getMetadataValue('blockType') == codeAttribution) {
      final language = node.getMetadataValue('language') as String?;
      firstLineCenter += 12;
      if (language != null && language.isNotEmpty) {
        final label = TextPainter(
          text: TextSpan(
            text: language,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        firstLineCenter += label.height;
        label.dispose();
      }
      child = Container(
        padding: const EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (language != null && language.isNotEmpty)
              Text(language, style: Theme.of(context).textTheme.labelSmall),
            child,
          ],
        ),
      );
    }
    if (node is TaskNode) {
      child = Semantics(
        container: true,
        label: 'Checkbox: ${node.text.toPlainText()}',
        checked: node.isComplete,
        enabled: !widget.readOnly,
        onTap: widget.readOnly
            ? null
            : () => _editor.execute([
                ChangeTaskCompletionRequest(
                  nodeId: node.id,
                  isComplete: !node.isComplete,
                ),
              ]),
        child: ExcludeSemantics(child: child),
      );
    }
    if (widget.readOnly) {
      return Padding(
        padding: const EdgeInsets.only(
          left: PaneSizes.blockGutter,
          right: PaneSizes.blockActions,
        ),
        child: AbsorbPointer(absorbing: node is TaskNode, child: child),
      );
    }
    final index = _draft.document.getNodeIndexById(id);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != id,
      onAcceptWithDetails: (details) => _move(details.data, index),
      builder: (context, candidates, rejected) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: PaneSizes.blockGutter,
            child: Draggable<String>(
              data: id,
              feedback: Material(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    node is TextNode ? node.text.toPlainText() : 'Block',
                  ),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(
                  top: (firstLineCenter - 9).clamp(0, double.infinity),
                ),
                child: const Icon(Icons.drag_indicator, size: 18),
              ),
            ),
          ),
          Expanded(child: child),
          SizedBox(
            width: PaneSizes.blockActions,
            child: AdaptiveMoreMenu(
              tooltip: 'Block actions',
              entries: [
                AdaptiveMenuEntry(
                  label: 'Insert block after',
                  onSelected: () => unawaited(_chooseBlock(id, insert: true)),
                ),
                if (node is TextNode)
                  AdaptiveMenuEntry(
                    label: 'Convert block',
                    onSelected: () => unawaited(_chooseBlock(id)),
                  ),
                if (node is OpaqueMarkdownNode)
                  AdaptiveMenuEntry(
                    label: 'Edit Markdown source',
                    onSelected: () => _switchMode(true, nodeId: id),
                  ),
                if (index > 0)
                  AdaptiveMenuEntry(
                    label: 'Move up',
                    onSelected: () => _move(id, index - 1),
                  ),
                if (index < _draft.document.nodeCount - 1)
                  AdaptiveMenuEntry(
                    label: 'Move down',
                    onSelected: () => _move(id, index + 1),
                  ),
                AdaptiveMenuEntry(
                  label: 'Delete block',
                  destructive: true,
                  onSelected: () => _delete(id),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _opaque(String source) =>
      widget.opaqueBuilder?.call(context, source) ??
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Markdown block'),
            Text(
              source,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final markdownStyles = AppTheme.markdown(context);
    final builders = [
      _OpaqueBuilder(_draft.document, _opaque, _blockFrame),
      for (final builder in [
        ...defaultComponentBuilders,
        TaskComponentBuilder(_editor),
      ])
        _FramedBuilder(builder, _blockFrame, widget.readOnly),
    ];
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _links?.value.isOpen == true) {
          _links?.close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: () => _switchMode(false),
                child: Text(
                  'Blocks',
                  style: !_sourceMode
                      ? const TextStyle(fontWeight: FontWeight.bold)
                      : null,
                ),
              ),
              TextButton(
                onPressed: () => _switchMode(true),
                child: Text(
                  'Markdown source',
                  style: _sourceMode
                      ? const TextStyle(fontWeight: FontWeight.bold)
                      : null,
                ),
              ),
              if (!_sourceMode && !widget.readOnly) ...[
                IconButton(
                  tooltip: 'Insert block',
                  icon: const Icon(Icons.add),
                  onPressed: () => unawaited(
                    _chooseBlock(
                      _composer.selection?.extent.nodeId,
                      insert: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Bold',
                  icon: const Icon(Icons.format_bold),
                  onPressed: () => _format(boldAttribution),
                ),
                IconButton(
                  tooltip: 'Italic',
                  icon: const Icon(Icons.format_italic),
                  onPressed: () => _format(italicsAttribution),
                ),
                IconButton(
                  tooltip: 'Inline code',
                  icon: const Icon(Icons.code),
                  onPressed: () => _format(codeAttribution),
                ),
                IconButton(
                  tooltip: 'Add link',
                  icon: const Icon(Icons.link),
                  onPressed: _link,
                ),
                IconButton(
                  tooltip: 'Undo',
                  icon: const Icon(Icons.undo),
                  onPressed: _editor.undo,
                ),
                IconButton(
                  tooltip: 'Redo',
                  icon: const Icon(Icons.redo),
                  onPressed: _editor.redo,
                ),
              ],
            ],
          ),
          if (!_sourceMode && widget.header != null) widget.header!,
          Expanded(
            child: _sourceMode
                ? widget.sourceBuilder?.call(
                        context,
                        _source,
                        widget.readOnly,
                      ) ??
                      TextField(
                        key: const ValueKey('block-source'),
                        controller: _source,
                        readOnly: widget.readOnly,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        onChanged: _publish,
                        decoration: const InputDecoration(
                          labelText: 'Markdown source',
                          alignLabelWithHint: true,
                          border: InputBorder.none,
                        ),
                      )
                : Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PaneSizes.editorPadding,
                    ),
                    child: AdaptiveSuperEditor(
                      editor: _editor,
                      document: _draft.document,
                      composer: _composer,
                      focusNode: _focus,
                      documentLayoutKey: _layoutKey,
                      readOnly: widget.readOnly,
                      componentBuilders: builders,
                      label: 'Note content',
                      stylesheet: defaultStylesheet.copyWith(
                        addRulesAfter: [
                          StyleRule(BlockSelector.all, (_, node) {
                            final type = node.getMetadataValue('blockType');
                            final style = switch (type) {
                              header1Attribution => markdownStyles.h1,
                              header2Attribution => markdownStyles.h2,
                              header3Attribution => markdownStyles.h3,
                              header4Attribution => markdownStyles.h4,
                              header5Attribution => markdownStyles.h5,
                              header6Attribution => markdownStyles.h6,
                              blockquoteAttribution =>
                                markdownStyles.blockquote,
                              codeAttribution => markdownStyles.code,
                              _ => markdownStyles.p,
                            };
                            return {Styles.textStyle: style};
                          }),
                        ],
                      ),
                      selectionPolicies: const SuperEditorSelectionPolicies(
                        clearSelectionWhenEditorLosesFocus: false,
                        clearSelectionWhenImeConnectionCloses: false,
                      ),
                    ),
                  ),
          ),
          if (!_sourceMode &&
              _links?.value.isOpen == true &&
              _links!.value.suggestions.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final title in _links!.value.suggestions)
                    TextButton(
                      onPressed: () => _insertWikiLink(title),
                      child: Text(title),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

enum _BlockKind {
  paragraph('Paragraph'),
  heading1('Heading 1'),
  heading2('Heading 2'),
  heading3('Heading 3'),
  heading4('Heading 4'),
  heading5('Heading 5'),
  heading6('Heading 6'),
  bullets('Bulleted list'),
  numbers('Numbered list'),
  task('Checkbox'),
  quote('Quote'),
  code('Code block'),
  divider('Divider');

  const _BlockKind(this.label);
  final String label;
}

class _FramedBuilder implements ComponentBuilder {
  _FramedBuilder(this.inner, this.frame, this.readOnly);
  final ComponentBuilder inner;
  final bool readOnly;
  final Widget Function(String, Widget, double) frame;
  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    final model = inner.createViewModel(document, node);
    if (readOnly && model is TaskComponentViewModel) model.setComplete = null;
    return model;
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext context,
    SingleColumnLayoutComponentViewModel model,
  ) {
    _normalizeBlockLayout(model);
    var firstLineCenter = 12.0;
    if (model is TextComponentViewModel) {
      final line = TextPainter(
        text: TextSpan(text: 'M', style: model.textStyleBuilder({})),
        textDirection: Directionality.of(context.context),
        textScaler: MediaQuery.textScalerOf(context.context),
      )..layout();
      firstLineCenter = line.height / 2;
      line.dispose();
      if (model is BlockquoteComponentViewModel) firstLineCenter += 16;
    }
    final child = model is TaskComponentViewModel
        ? _AlignedTaskComponent(
            key: context.componentKey,
            viewModel: model,
            firstLineHeight: firstLineCenter * 2,
          )
        : inner.createComponent(context, model);
    return child == null ? null : frame(model.nodeId, child, firstLineCenter);
  }
}

class _OpaqueBuilder implements ComponentBuilder {
  _OpaqueBuilder(this.document, this.render, this.frame);
  final Document document;
  final Widget Function(String) render;
  final Widget Function(String, Widget, double) frame;
  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) => node is OpaqueMarkdownNode
      ? _OpaqueViewModel(node.id, node.source)
      : null;
  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext context,
    SingleColumnLayoutComponentViewModel model,
  ) {
    if (model is! _OpaqueViewModel) return null;
    _normalizeBlockLayout(model);
    return frame(
      model.nodeId,
      BoxComponent(key: context.componentKey, child: render(model.source)),
      12,
    );
  }
}

class _OpaqueViewModel extends SingleColumnLayoutComponentViewModel {
  _OpaqueViewModel(String id, this.source)
    : super(nodeId: id, createdAt: null, padding: EdgeInsets.zero);
  final String source;
  @override
  SingleColumnLayoutComponentViewModel copy() =>
      _OpaqueViewModel(nodeId, source)..padding = padding;
}

void _normalizeBlockLayout(SingleColumnLayoutComponentViewModel model) {
  final padding = model.padding.resolve(TextDirection.ltr);
  model.maxWidth = double.infinity;
  model.padding = EdgeInsets.only(
    top: padding.top.clamp(0, 16),
    bottom: padding.bottom,
  );
}

class _AlignedTaskComponent extends StatefulWidget {
  const _AlignedTaskComponent({
    required this.viewModel,
    required this.firstLineHeight,
    super.key,
  });
  final TaskComponentViewModel viewModel;
  final double firstLineHeight;

  @override
  State<_AlignedTaskComponent> createState() => _AlignedTaskComponentState();
}

class _AlignedTaskComponentState extends State<_AlignedTaskComponent>
    with ProxyDocumentComponent<_AlignedTaskComponent>, ProxyTextComposable {
  final _textKey = GlobalKey();

  @override
  GlobalKey get childDocumentComponentKey => _textKey;

  @override
  TextComposable get childTextComposable =>
      _textKey.currentState as TextComposable;

  TextStyle _textStyle(Set<Attribution> attributions) {
    final style = widget.viewModel.textStyleBuilder(attributions);
    return widget.viewModel.isComplete
        ? style.copyWith(
            decoration: TextDecoration.combine([
              if (style.decoration != null) style.decoration!,
              TextDecoration.lineThrough,
            ]),
          )
        : style;
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.viewModel;
    return Directionality(
      textDirection: model.textDirection,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: model.setComplete == null
                ? null
                : () => model.setComplete!(!model.isComplete),
            child: SizedBox(
              width: 26,
              height: widget.firstLineHeight.clamp(44, double.infinity),
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: (widget.firstLineHeight / 2 - 9).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: legacy.Checkbox(
                      value: model.isComplete,
                      onChanged: model.setComplete == null
                          ? null
                          : (value) => model.setComplete!(value!),
                      materialTapTargetSize:
                          legacy.MaterialTapTargetSize.shrinkWrap,
                      visualDensity: legacy.VisualDensity.compact,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: TextComponent(
              key: _textKey,
              text: model.text,
              textDirection: model.textDirection,
              textAlign: model.textAlignment,
              maxLines: model.maxLines,
              overflow: model.overflow,
              textStyleBuilder: _textStyle,
              inlineWidgetBuilders: model.inlineWidgetBuilders,
              textSelection: model.selection,
              selectionColor: model.selectionColor,
              highlightWhenEmpty: model.highlightWhenEmpty,
              underlines: model.createUnderlines(),
            ),
          ),
        ],
      ),
    );
  }
}
