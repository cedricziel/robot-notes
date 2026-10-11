import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_editor/super_editor.dart';

import 'theme_bridge.dart';

/// Adapts a nonempty Super Editor document to the host theme and text semantics.
/// The caller owns the editor, document, composer, and focus node.
class AdaptiveSuperEditor extends StatefulWidget {
  const AdaptiveSuperEditor({
    required this.editor,
    required this.document,
    required this.composer,
    required this.focusNode,
    this.readOnly = false,
    this.onPaste,
    this.inputSource,
    this.componentBuilders,
    this.stylesheet,
    this.documentLayoutKey,
    this.selectionPolicies,
    this.label = 'Document',
    super.key,
  });

  final Editor editor;
  final MutableDocument document;
  final MutableDocumentComposer composer;
  final FocusNode focusNode;
  final bool readOnly;

  /// Handles clipboard reads and insertion for editor paste gestures.
  final Future<void> Function()? onPaste;
  final TextInputSource? inputSource;
  final List<ComponentBuilder>? componentBuilders;
  final Stylesheet? stylesheet;
  final GlobalKey? documentLayoutKey;
  final SuperEditorSelectionPolicies? selectionPolicies;
  final String label;

  @override
  State<AdaptiveSuperEditor> createState() => _AdaptiveSuperEditorState();
}

class _AdaptiveSuperEditorState extends State<AdaptiveSuperEditor> {
  final _inputRole = Editor.createNodeId();
  final _fallbackLayoutKey = GlobalKey();
  late final SuperEditorIosControlsController _iosControls =
      SuperEditorIosControlsController(
        toolbarBuilder: (context, key, focalPoint) =>
            defaultIosEditorToolbarBuilder(
              context,
              key,
              focalPoint,
              _toolbarOperations,
              _iosControls,
            ),
      );
  late final SuperEditorAndroidControlsController _androidControls =
      SuperEditorAndroidControlsController(
        toolbarBuilder: (context, key, focalPoint) =>
            defaultAndroidEditorToolbarBuilder(
              context,
              key,
              _toolbarOperations,
              _androidControls,
              widget.composer.selectionNotifier,
              focalPoint,
            ),
      );

  GlobalKey get _layoutKey => widget.documentLayoutKey ?? _fallbackLayoutKey;

  CommonEditorOperations get _toolbarOperations => _PasteEditorOperations(
    document: widget.document,
    editor: widget.editor,
    composer: widget.composer,
    documentLayoutResolver: () => _layoutKey.currentState as DocumentLayout,
    onPaste: _paste,
  );

  void _paste() {
    if (!mounted || widget.readOnly) return;
    final callback = widget.onPaste;
    if (callback != null) unawaited(callback());
  }

  ExecutionInstruction _pasteShortcut({
    required SuperEditorContext editContext,
    required KeyEvent keyEvent,
  }) {
    if ((keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) ||
        !keyEvent.isPrimaryShortcutKeyPressed ||
        keyEvent.logicalKey != LogicalKeyboardKey.keyV) {
      return ExecutionInstruction.continueExecution;
    }
    _paste();
    return ExecutionInstruction.haltExecution;
  }

  final _imeValues = _CompleteImeValues();

  @override
  void initState() {
    super.initState();
    _listen(widget);
  }

  void _listen(AdaptiveSuperEditor editor) {
    editor.document.addListener(_documentChanged);
    editor.composer.selectionNotifier.addListener(_changed);
    editor.focusNode.addListener(_changed);
  }

  void _unlisten(AdaptiveSuperEditor editor) {
    editor.document.removeListener(_documentChanged);
    editor.composer.selectionNotifier.removeListener(_changed);
    editor.focusNode.removeListener(_changed);
  }

  @override
  void didUpdateWidget(AdaptiveSuperEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document) ||
        !identical(oldWidget.composer, widget.composer) ||
        !identical(oldWidget.focusNode, widget.focusNode)) {
      _unlisten(oldWidget);
      _listen(widget);
    }
  }

  @override
  void dispose() {
    _unlisten(widget);
    _iosControls.dispose();
    _androidControls.dispose();
    super.dispose();
  }

  void _documentChanged(DocumentChangeLog _) => _changed();

  void _changed() {
    if (mounted) setState(() {});
  }

  DocumentImeSerializer get _projection => DocumentImeSerializer(
    widget.document,
    DocumentSelection(
      base: DocumentPosition(
        nodeId: widget.document.first.id,
        nodePosition: widget.document.first.beginningPosition,
      ),
      extent: DocumentPosition(
        nodeId: widget.document.last.id,
        nodePosition: widget.document.last.endPosition,
      ),
    ),
    null,
    PrependedCharacterPolicy.exclude,
  );

  void _select(TextSelection selection) {
    final projection = _projection;
    if (!selection.isValid || selection.end > projection.imeText.length) return;
    final mapped = projection.imeToDocumentSelection(selection);
    if (mapped == null) return;
    widget.editor.execute([
      ChangeSelectionRequest(
        mapped,
        selection.isCollapsed
            ? SelectionChangeType.placeCaret
            : SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
    ]);
  }

  void _focus() {
    widget.focusNode.requestFocus();
    if (widget.composer.selection == null) {
      _select(const TextSelection.collapsed(offset: 0));
    }
  }

  void _replaceText(String text) {
    if (widget.readOnly) return;
    final projection = _projection;
    final previous = projection.imeText;
    if (previous == text) return;
    var start = 0;
    while (start < previous.length &&
        start < text.length &&
        previous.codeUnitAt(start) == text.codeUnitAt(start)) {
      start++;
    }
    if (start > 0 &&
        start < previous.length &&
        _highSurrogate(previous.codeUnitAt(start - 1))) {
      start--;
    }
    var oldEnd = previous.length;
    var newEnd = text.length;
    while (oldEnd > start &&
        newEnd > start &&
        previous.codeUnitAt(oldEnd - 1) == text.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    if (oldEnd < previous.length &&
        oldEnd > start &&
        _highSurrogate(previous.codeUnitAt(oldEnd - 1))) {
      oldEnd++;
      newEnd++;
    }
    final selection = projection.imeToDocumentSelection(
      TextSelection(baseOffset: start, extentOffset: oldEnd),
    );
    if (selection == null) return;
    final replacement = text.substring(start, newEnd).split('\n');
    final requests = <EditRequest>[
      ChangeSelectionRequest(
        selection,
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
      if (!selection.isCollapsed)
        const DeleteSelectionRequest(TextAffinity.downstream),
      for (var i = 0; i < replacement.length; i++) ...[
        if (replacement[i].isNotEmpty)
          InsertPlainTextAtCaretRequest(replacement[i]),
        if (i < replacement.length - 1) InsertNewlineAtCaretRequest(),
      ],
      ChangeComposingRegionRequest(null),
    ];
    widget.editor.execute(requests);
  }

  void _moveCursor({
    required bool forward,
    required bool extendSelection,
    bool byWord = false,
  }) {
    final projection = _projection;
    final current = widget.composer.selection == null
        ? const TextSelection.collapsed(offset: 0)
        : projection.documentToImeSelection(widget.composer.selection!);
    TextPainter? painter;
    final TextBoundary boundary;
    if (byWord) {
      painter = TextPainter(
        text: TextSpan(text: projection.imeText),
        textDirection: Directionality.of(context),
      )..layout();
      boundary = painter.wordBoundaries.moveByWordBoundary;
    } else {
      boundary = CharacterBoundary(projection.imeText);
    }
    final next = forward
        ? boundary.getTrailingTextBoundaryAt(current.extentOffset) ??
              projection.imeText.length
        : boundary.getLeadingTextBoundaryAt(current.extentOffset - 1) ?? 0;
    painter?.dispose();
    _select(
      TextSelection(
        baseOffset: extendSelection ? current.baseOffset : next,
        extentOffset: next,
      ),
    );
  }

  TextStyle _textStyle(ThemeData theme, DocumentNode node) {
    final type = node.getMetadataValue('blockType');
    final block = type is NamedAttribution ? type.id : '';
    final base = switch (block) {
      'header1' => theme.textTheme.displaySmall,
      'header2' => theme.textTheme.headlineMedium,
      'header3' => theme.textTheme.headlineSmall,
      'header4' => theme.textTheme.titleLarge,
      'header5' => theme.textTheme.titleMedium,
      'header6' => theme.textTheme.titleSmall,
      _ => theme.textTheme.bodyLarge,
    };
    return (base ?? const TextStyle()).copyWith(
      color: theme.colorScheme.onSurface,
    );
  }

  static bool _highSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  @override
  Widget build(BuildContext context) {
    assert(widget.document.nodeCount > 0);
    final theme = Theme.of(context);
    final projection = _projection;
    final selection = widget.composer.selection;
    final gestureMode = switch (theme.platform) {
      TargetPlatform.iOS => DocumentGestureMode.iOS,
      TargetPlatform.android => DocumentGestureMode.android,
      _ => DocumentGestureMode.mouse,
    };
    final styles =
        widget.stylesheet ??
        defaultStylesheet.copyWith(
          addRulesAfter: [
            StyleRule(
              BlockSelector.all,
              (_, node) => {Styles.textStyle: _textStyle(theme, node)},
            ),
          ],
        );
    final selectionStyles = SelectionStyles(
      selectionColor:
          theme.textSelectionTheme.selectionColor ??
          theme.colorScheme.primary.withValues(alpha: 0.3),
    );
    final editor = widget.readOnly
        ? SuperReader(
            editor: widget.editor,
            focusNode: widget.focusNode,
            documentLayoutKey: _layoutKey,
            componentBuilders: widget.componentBuilders,
            stylesheet: styles,
            gestureMode: gestureMode,
            selectionStyle: selectionStyles,
            contentTapDelegateFactory: (_) => _PassiveTapDelegate(),
          )
        : SuperEditor(
            editor: widget.editor,
            inputRole: _inputRole,
            keyboardActions: widget.onPaste == null
                ? null
                : [
                    _pasteShortcut,
                    ...(widget.inputSource == TextInputSource.keyboard
                        ? defaultKeyboardActions
                        : defaultImeKeyboardActions),
                  ],
            selectorHandlers: widget.onPaste == null
                ? null
                : {...defaultEditorSelectorHandlers, 'paste:': (_) => _paste()},
            imeOverrides: _imeValues,
            imeConfiguration: kIsWeb
                ? _WebImeConfiguration(keyboardBrightness: theme.brightness)
                : null,
            focusNode: widget.focusNode,
            documentLayoutKey: _layoutKey,
            componentBuilders: widget.componentBuilders,
            stylesheet: styles,
            inputSource: widget.inputSource,
            selectionPolicies:
                widget.selectionPolicies ??
                const SuperEditorSelectionPolicies(
                  clearSelectionWhenEditorLosesFocus: false,
                  clearSelectionWhenImeConnectionCloses: false,
                ),
            gestureMode: gestureMode,
            selectionStyle: selectionStyles,
            contentTapDelegateFactories: const [],
            iOSHandleColor: theme.colorScheme.primary,
            androidHandleColor: theme.colorScheme.primary,
          );
    return _DocumentSemantics(
      selection: selection == null
          ? null
          : projection.documentToImeSelection(selection),
      properties: SemanticsProperties(
        label: widget.label,
        textDirection: Directionality.of(context),
        textField: true,
        multiline: true,
        enabled: true,
        readOnly: widget.readOnly,
        focused: widget.focusNode.hasFocus,
        value: projection.imeText,
        onFocus: _focus,
        onTap: _focus,
        onSetSelection: _select,
        onMoveCursorForwardByCharacter: (extend) =>
            _moveCursor(forward: true, extendSelection: extend),
        onMoveCursorBackwardByCharacter: (extend) =>
            _moveCursor(forward: false, extendSelection: extend),
        onMoveCursorForwardByWord: (extend) =>
            _moveCursor(forward: true, extendSelection: extend, byWord: true),
        onMoveCursorBackwardByWord: (extend) =>
            _moveCursor(forward: false, extendSelection: extend, byWord: true),
        onSetText: widget.readOnly ? null : _replaceText,
      ),
      child: SuperEditorThemeBridge(
        child: widget.onPaste == null || widget.readOnly
            ? editor
            : switch (gestureMode) {
                DocumentGestureMode.iOS => SuperEditorIosControlsScope(
                  controller: _iosControls,
                  child: editor,
                ),
                DocumentGestureMode.android => SuperEditorAndroidControlsScope(
                  controller: _androidControls,
                  child: editor,
                ),
                DocumentGestureMode.mouse => editor,
              },
      ),
    );
  }
}

class _PassiveTapDelegate extends ContentTapDelegate {}

class _DocumentSemantics extends SingleChildRenderObjectWidget {
  const _DocumentSemantics({
    required this.properties,
    required this.selection,
    required super.child,
  });

  final SemanticsProperties properties;
  final TextSelection? selection;

  @override
  _DocumentSemanticsRender createRenderObject(BuildContext context) =>
      _DocumentSemanticsRender(
        properties: properties,
        selection: selection,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _DocumentSemanticsRender renderObject,
  ) {
    renderObject.properties = properties;
    renderObject.selection = selection;
    renderObject.textDirection = Directionality.of(context);
  }
}

class _DocumentSemanticsRender extends RenderSemanticsAnnotations {
  _DocumentSemanticsRender({
    required super.properties,
    required super.textDirection,
    required TextSelection? selection,
  }) : _selection = selection,
       super(container: true, explicitChildNodes: true);

  TextSelection? _selection;

  set selection(TextSelection? value) {
    if (_selection == value) return;
    _selection = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (_selection != null) config.textSelection = _selection;
  }
}

// Web semantics omits beforeinput, so its delta model loses inserted text.
// Complete values also support engines that send a non-delta update unexpectedly.
class _CompleteImeValues extends DeltaTextInputClientDecorator {
  @override
  void updateEditingValue(TextEditingValue value) {
    final previous = currentTextEditingValue;
    if (previous == null) return;
    if (previous.text == value.text) {
      updateEditingValueWithDeltas([
        TextEditingDeltaNonTextUpdate(
          oldText: previous.text,
          selection: value.selection,
          composing: value.composing,
        ),
      ]);
      return;
    }
    var start = 0;
    while (start < previous.text.length &&
        start < value.text.length &&
        previous.text.codeUnitAt(start) == value.text.codeUnitAt(start)) {
      start++;
    }
    if (start > 0 &&
        start < previous.text.length &&
        _AdaptiveSuperEditorState._highSurrogate(
          previous.text.codeUnitAt(start - 1),
        )) {
      start--;
    }
    var oldEnd = previous.text.length;
    var newEnd = value.text.length;
    while (oldEnd > start &&
        newEnd > start &&
        previous.text.codeUnitAt(oldEnd - 1) ==
            value.text.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    if (oldEnd < previous.text.length &&
        oldEnd > start &&
        _AdaptiveSuperEditorState._highSurrogate(
          previous.text.codeUnitAt(oldEnd - 1),
        )) {
      oldEnd++;
      newEnd++;
    }
    final inserted = value.text.substring(start, newEnd);
    updateEditingValueWithDeltas([
      if (oldEnd == start)
        TextEditingDeltaInsertion(
          oldText: previous.text,
          textInserted: inserted,
          insertionOffset: start,
          selection: value.selection,
          composing: value.composing,
        )
      else if (inserted.isEmpty)
        TextEditingDeltaDeletion(
          oldText: previous.text,
          deletedRange: TextRange(start: start, end: oldEnd),
          selection: value.selection,
          composing: value.composing,
        )
      else
        TextEditingDeltaReplacement(
          oldText: previous.text,
          replacementText: inserted,
          replacedRange: TextRange(start: start, end: oldEnd),
          selection: value.selection,
          composing: value.composing,
        ),
    ]);
  }
}

class _WebImeConfiguration extends SuperEditorImeConfiguration {
  const _WebImeConfiguration({super.keyboardBrightness});

  @override
  TextInputConfiguration toTextInputConfiguration({required int viewId}) =>
      super
          .toTextInputConfiguration(viewId: viewId)
          .copyWith(enableDeltaModel: false);
}

class _PasteEditorOperations extends CommonEditorOperations {
  _PasteEditorOperations({
    required super.document,
    required super.editor,
    required super.composer,
    required super.documentLayoutResolver,
    required this.onPaste,
  });

  final VoidCallback onPaste;

  @override
  void paste() => onPaste();
}
