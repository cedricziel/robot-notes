import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:super_editor/super_editor.dart';

/// Marks a literal `[[Title]]` token, including its brackets, as a wiki link.
/// This attribution preserves note syntax without resolving or launching a URL.
const wikiLinkAttribution = NamedAttribution('wikiLink');

const _literalWikiLinkAttribution = NamedAttribution('literalWikiLink');
final _wikiToken = RegExp(r'\[\[[^\[\]\r\n]*(?:\]\]|$)');

/// Creates the standard editor pipeline with undoable Markdown replacement.
Editor createMarkdownDocumentEditor({
  required MutableDocument document,
  required MutableDocumentComposer composer,
  bool isHistoryEnabled = true,
}) {
  final editor = createDefaultDocumentEditor(
    document: document,
    composer: composer,
    isHistoryEnabled: isHistoryEnabled,
  );
  editor.requestHandlers.insert(
    0,
    (_, request) => request is ReplaceDocumentRequest
        ? ReplaceDocumentCommand(request.nodes)
        : null,
  );
  return editor;
}

/// An editable projection whose unchanged nodes retain their original Markdown.
/// IDs and provenance are session-local and never appear in serialized source.
class MarkdownEditingDocument {
  MarkdownEditingDocument._(this.document, this._sources);

  factory MarkdownEditingDocument.fromMarkdown(
    String source, {
    String Function()? nodeIdGenerator,
  }) {
    final parser = _MarkdownParser(
      source,
      nodeIdGenerator ?? Editor.createNodeId,
    );
    return parser.parse();
  }

  final MutableDocument document;
  final Map<String, _NodeSource> _sources;

  /// Serializes only changed blocks, repairing delimiters after structural edits.
  String toMarkdown() => _serialize().source;

  /// Returns the current serialized body of [id], excluding block separators.
  String sourceForNode(String id) {
    final output = _serialize();
    final range = output.ranges[id];
    if (range == null) throw ArgumentError.value(id, 'id', 'Unknown node');
    return output.source.substring(range.start, range.end);
  }

  /// Returns UTF-16 offsets into [toMarkdown] for the current body of [id].
  TextRange sourceRangeForNode(String id) {
    final range = _serialize().ranges[id];
    if (range == null) throw ArgumentError.value(id, 'id', 'Unknown node');
    return range;
  }

  /// Replaces content in the existing document through an undoable transaction.
  /// The editor must handle [ReplaceDocumentRequest] with [ReplaceDocumentCommand].
  void replaceMarkdown(String source, Editor editor) {
    final replacement = MarkdownEditingDocument.fromMarkdown(source);
    retainSources(replacement);
    editor.execute([ReplaceDocumentRequest(replacement.document.toList())]);
  }

  /// Retains a parsed fragment's provenance before inserting its nodes.
  void retainSources(MarkdownEditingDocument fragment) {
    _sources.addAll(fragment._sources);
  }

  _SerializedMarkdown _serialize() {
    final output = StringBuffer();
    final ranges = <String, TextRange>{};
    DocumentNode? previous;
    var previousUnchanged = false;
    for (final node in document) {
      final provenance = _sources[node.id];
      final unchanged = provenance?.matches(node) ?? false;
      if (previous == null) {
        if (provenance?.previousId == null)
          output.write(provenance?.before ?? '');
      } else {
        final adjacent = provenance?.previousId == previous.id;
        if (adjacent && unchanged && previousUnchanged) {
          output.write(provenance!.before);
        } else {
          final minimum = _sameListKind(previous, node) ? 1 : 2;
          final gap = adjacent ? provenance!.before : '';
          final newline = gap.contains('\r\n') ? '\r\n' : '\n';
          output.write(
            '\n'.allMatches(gap).length >= minimum ? gap : newline * minimum,
          );
        }
      }
      final start = output.length;
      output.write(unchanged ? provenance!.body : _serializeNode(node));
      ranges[node.id] = TextRange(start: start, end: output.length);
      previous = node;
      previousUnchanged = unchanged;
    }
    if (previous != null) output.write(_sources[previous.id]?.after ?? '');
    return _SerializedMarkdown(output.toString(), ranges);
  }
}

/// Unsupported syntax retained as exact source for rendering or source editing.
class OpaqueMarkdownNode extends BlockNode {
  OpaqueMarkdownNode({
    required this.id,
    required this.source,
    Map<String, dynamic>? metadata,
  }) : super(metadata: _freezeMetadata(metadata ?? const {}));

  @override
  final String id;
  final String source;
  String get rawMarkdown => source;

  @override
  Map<String, dynamic> get metadata => Map.unmodifiable(super.metadata);

  @override
  String? copyContent(NodeSelection selection) => source;

  @override
  bool hasEquivalentContent(DocumentNode other) =>
      other is OpaqueMarkdownNode &&
      other.source == source &&
      super.hasEquivalentContent(other);

  @override
  OpaqueMarkdownNode copyWithAddedMetadata(
    Map<String, dynamic> newProperties,
  ) => OpaqueMarkdownNode(
    id: id,
    source: source,
    metadata: {...metadata, ...newProperties},
  );

  @override
  OpaqueMarkdownNode copyAndReplaceMetadata(Map<String, dynamic> newMetadata) =>
      OpaqueMarkdownNode(id: id, source: source, metadata: newMetadata);
}

class _NodeSource {
  _NodeSource({
    required this.snapshot,
    required this.body,
    required this.before,
    required this.previousId,
  });
  final DocumentNode snapshot;
  final String body;
  final String before;
  final String? previousId;
  String after = '';

  bool matches(DocumentNode node) =>
      node.runtimeType == snapshot.runtimeType &&
      node.hasEquivalentContent(snapshot) &&
      node.getMetadataValue('blockType') ==
          snapshot.getMetadataValue('blockType') &&
      node.getMetadataValue('language') ==
          snapshot.getMetadataValue('language') &&
      node.getMetadataValue('ordinal') == snapshot.getMetadataValue('ordinal');
}

class _SerializedMarkdown {
  _SerializedMarkdown(this.source, this.ranges);
  final String source;
  final Map<String, TextRange> ranges;
}

class _Line {
  _Line(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

final _heading = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*)|[ \t]*)$');
final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
final _list = RegExp(r'^ {0,3}(?:([-+*])|([0-9]{1,9})[.)])[ \t]+(.*)$');
final _rule = RegExp(
  r'^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$',
);
final _quote = RegExp(r'^ {0,3}>[ \t]?(.*)$');

class _MarkdownParser {
  _MarkdownParser(this.source, this.newId) {
    for (final match in RegExp(r'[^\n]*(?:\n|$)').allMatches(source)) {
      if (match.start == source.length) break;
      final raw = match.group(0)!;
      final text = raw.replaceFirst(RegExp(r'\r?\n$'), '');
      lines.add(_Line(match.start, match.start + text.length, text));
    }
  }

  final String source;
  final String Function() newId;
  final lines = <_Line>[];
  final nodes = <DocumentNode>[];
  final provenance = <String, _NodeSource>{};
  var previousEnd = 0;

  MarkdownEditingDocument parse() {
    var index = 0;
    while (index < lines.length) {
      if (lines[index].text.trim().isEmpty) {
        index++;
        continue;
      }
      final start = index;
      final text = lines[index].text;
      final html = RegExp(r'^ {0,3}<([A-Za-z][A-Za-z0-9-]*)(?:[ \t>/]|$)')
          .firstMatch(text);
      final comment = text.trimLeft().startsWith('<!--');
      if (html != null || comment) {
        final tag = html?.group(1)?.toLowerCase();
        final terminator = comment ? '-->' : '</$tag>';
        final single =
            tag != null &&
            (RegExp(
                  '^ {0,3}<${RegExp.escape(tag)}[^>]*/>[ \\t]*\$',
                  caseSensitive: false,
                ).hasMatch(text) ||
                const {
                  'hr',
                  'br',
                  'img',
                  'input',
                  'meta',
                  'link',
                  'area',
                  'base',
                  'col',
                  'embed',
                  'param',
                  'source',
                  'track',
                  'wbr',
                }.contains(tag));
        if (single) {
          _add(start, ++index, _opaque(start, index));
          continue;
        }
        var depth = 0;
        var closed = false;
        final tags = tag == null
            ? null
            : RegExp(
                '</?${RegExp.escape(tag)}(?=[ \\t>/])[^>]*>',
                caseSensitive: false,
              );
        while (index < lines.length) {
          final line = lines[index].text;
          if (comment) {
            closed = line.contains(terminator);
          } else {
            for (final match in tags!.allMatches(line)) {
              final token = match.group(0)!;
              if (token.startsWith('</')) {
                depth--;
              } else if (!token.endsWith('/>')) {
                depth++;
              }
            }
            closed = depth <= 0;
          }
          index++;
          if (closed) break;
        }
        if (!closed) return _allOpaque();
        _add(start, index, _opaque(start, index));
        continue;
      }
      final fence = _fence.firstMatch(text);
      if (fence != null) {
        final marker = fence.group(1)!;
        index++;
        while (index < lines.length &&
            !RegExp(
              '^ {0,3}${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\$',
            ).hasMatch(lines[index].text)) {
          index++;
        }
        if (index == lines.length) return _allOpaque();
        final language = fence.group(2)!.trim();
        final contentIndent = RegExp('^ {0,${text.indexOf(marker)}}');
        final content = lines
            .sublist(start + 1, index)
            .map((line) => line.text.replaceFirst(contentIndent, ''))
            .join('\n');
        index++;
        _add(
          start,
          index,
          language == 'database' ||
                  language.contains(RegExp(r'\s')) ||
                  (marker[0] == '`' && language.contains('`'))
              ? _opaque(start, index)
              : ParagraphNode(
                  id: newId(),
                  text: AttributedText(content),
                  metadata: {
                    'blockType': codeAttribution,
                    'language': language,
                  },
                ),
        );
        continue;
      }
      final heading = _heading.firstMatch(text);
      if (heading != null) {
        index++;
        final content = (heading.group(2) ?? '')
            .replaceFirst(RegExp(r'[ \t]+#+[ \t]*$'), '')
            .trimRight();
        final inline = _parseInline(content);
        _add(
          start,
          index,
          inline == null
              ? _opaque(start, index)
              : ParagraphNode(
                  id: newId(),
                  text: inline,
                  metadata: {
                    'blockType': NamedAttribution(
                      'header${heading.group(1)!.length}',
                    ),
                  },
                ),
        );
        continue;
      }
      if (_rule.hasMatch(text)) {
        _add(start, ++index, HorizontalRuleNode(id: newId()));
        continue;
      }
      if (_list.hasMatch(text)) {
        index++;
        while (index < lines.length) {
          if (_list.hasMatch(lines[index].text) ||
              RegExp(r'^[ \t]+\S').hasMatch(lines[index].text)) {
            index++;
            continue;
          }
          if (lines[index].text.trim().isNotEmpty &&
              !_startsBlock(lines[index].text)) {
            index++;
            continue;
          }
          if (lines[index].text.trim().isEmpty) {
            var next = index + 1;
            while (next < lines.length && lines[next].text.trim().isEmpty) {
              next++;
            }
            if (next < lines.length &&
                (_list.hasMatch(lines[next].text) ||
                    RegExp(r'^[ \t]+\S').hasMatch(lines[next].text))) {
              index = next;
              continue;
            }
          }
          break;
        }
        final nested = lines
            .sublist(start, index)
            .any(
              (line) =>
                  (line.text.trim().isNotEmpty && !_list.hasMatch(line.text)) ||
                  line.text.startsWith(' ') ||
                  line.text.startsWith('\t'),
            );
        if (nested) {
          _add(start, index, _opaque(start, index));
        } else {
          for (var item = start; item < index; item++) {
            if (lines[item].text.trim().isEmpty) continue;
            final match = _list.firstMatch(lines[item].text)!;
            final task = RegExp(r'^\[([ xX])\][ \t]+(.*)$')
                .firstMatch(match.group(3)!);
            final inline = _parseInline(task?.group(2) ?? match.group(3)!);
            final node = inline == null
                ? _opaque(item, item + 1)
                : task != null
                ? TaskNode(
                    id: newId(),
                    text: inline,
                    isComplete: task.group(1)!.toLowerCase() == 'x',
                  )
                : ListItemNode(
                    id: newId(),
                    text: inline,
                    itemType: match.group(2) == null
                        ? ListItemType.unordered
                        : ListItemType.ordered,
                    metadata: {
                      if (match.group(2) != null)
                        'ordinal': int.parse(match.group(2)!),
                    },
                  );
            _add(item, item + 1, node);
          }
        }
        continue;
      }
      if (_quote.hasMatch(text)) {
        index++;
        while (index < lines.length &&
            lines[index].text.trim().isNotEmpty &&
            (_quote.hasMatch(lines[index].text) ||
                !_startsBlock(lines[index].text))) {
          index++;
        }
        if (lines
            .sublist(start, index)
            .any((line) => !_quote.hasMatch(line.text))) {
          _add(start, index, _opaque(start, index));
          continue;
        }
        final content = lines
            .sublist(start, index)
            .map((line) => _quote.firstMatch(line.text)!.group(1)!)
            .join('\n');
        final inline =
            RegExp(r'(^|\n)(?:>|#{1,6}\s|[-+*]\s|\d+[.)]\s|`{3}|~{3})')
                .hasMatch(content)
            ? null
            : _parseInline(content);
        _add(
          start,
          index,
          inline == null
              ? _opaque(start, index)
              : ParagraphNode(
                  id: newId(),
                  text: inline,
                  metadata: {'blockType': blockquoteAttribution},
                ),
        );
        continue;
      }
      index++;
      while (index < lines.length &&
          lines[index].text.trim().isNotEmpty &&
          !_startsBlock(lines[index].text)) {
        index++;
      }
      // Setext underlines belong to the preceding block, so splitting them is unsafe.
      if (index < lines.length &&
          RegExp(r'^ {0,3}(?:-+|=+)[ \t]*$').hasMatch(lines[index].text)) {
        index++;
      }
      final body = _body(start, index);
      final unsupported = RegExp(
        r'(^|\n)(?: {4}|\t|\[[^\]]+\]:|<|=+\s*$)|\n {0,3}(?:-+|=+)[ \t]*(?:\n|$)|\|.*\n.*\|',
      ).hasMatch(body.replaceAll('\r\n', '\n'));
      final inline = unsupported
          ? null
          : _parseInline(body.replaceAll('\r\n', '\n'));
      _add(
        start,
        index,
        inline == null
            ? _opaque(start, index)
            : ParagraphNode(id: newId(), text: inline),
      );
    }
    if (nodes.isEmpty) {
      final node = ParagraphNode(id: newId(), text: AttributedText(''));
      nodes.add(node);
      provenance[node.id] = _NodeSource(
        snapshot: node.copy(),
        body: '',
        before: source,
        previousId: null,
      );
    } else {
      provenance[nodes.last.id]!.after = source.substring(previousEnd);
    }
    return MarkdownEditingDocument._(MutableDocument(nodes: nodes), provenance);
  }

  bool _startsBlock(String text) =>
      _heading.hasMatch(text) ||
      _fence.hasMatch(text) ||
      _list.hasMatch(text) ||
      _quote.hasMatch(text) ||
      _rule.hasMatch(text);
  String _body(int start, int end) =>
      source.substring(lines[start].start, lines[end - 1].end);
  OpaqueMarkdownNode _opaque(int start, int end) =>
      OpaqueMarkdownNode(id: newId(), source: _body(start, end));

  void _add(int start, int end, DocumentNode node) {
    final snapshot = node is TextNode
        ? node.copy()
        : node.copyAndReplaceMetadata(node.metadata);
    provenance[node.id] = _NodeSource(
      snapshot: snapshot,
      body: _body(start, end),
      before: source.substring(previousEnd, lines[start].start),
      previousId: nodes.isEmpty ? null : nodes.last.id,
    );
    previousEnd = lines[end - 1].end;
    nodes.add(node);
  }

  MarkdownEditingDocument _allOpaque() {
    final node = OpaqueMarkdownNode(id: newId(), source: source);
    return MarkdownEditingDocument._(MutableDocument(nodes: [node]), {
      node.id: _NodeSource(
        snapshot: node,
        body: source,
        before: '',
        previousId: null,
      ),
    });
  }
}

AttributedText? _parseInline(String source) {
  if (RegExp(r'!\[').hasMatch(source)) return null;
  final validation = source
      .replaceAll(RegExp(r'\\[\\`*_{}\[\]()#+\-.!>~]'), 'x')
      .replaceAll(_wikiToken, 'x');
  if (RegExp(r'\{\{|<|~~|\$|[ \t]{2,}\n|\\\n').hasMatch(validation))
    return null;
  if (RegExp(r'\[[^\]]*\](?!\()').hasMatch(validation)) return null;
  final ast = md.Document(
    encodeHtml: false,
    inlineSyntaxes: [_EscapedWikiLinkSyntax(), _WikiLinkSyntax()],
  ).parseInline(source);
  final text = StringBuffer();
  final spans = <(Attribution, int, int)>[];
  var supported = true;
  void visit(md.Node node) {
    if (node is md.Text) {
      text.write(node.text);
      return;
    }
    if (node is! md.Element) {
      supported = false;
      return;
    }
    final Attribution? attribution = switch (node.tag) {
      'strong' => boldAttribution,
      'em' => italicsAttribution,
      'code' => codeAttribution,
      'wiki-link' => wikiLinkAttribution,
      'literal-wiki-link' => _literalWikiLinkAttribution,
      'a' => LinkAttribution(node.attributes['href'] ?? ''),
      _ => null,
    };
    if (attribution == null || node.attributes.containsKey('title')) {
      supported = false;
      return;
    }
    final start = text.length;
    for (final child in node.children ?? <md.Node>[]) {
      visit(child);
    }
    if (text.length > start) spans.add((attribution, start, text.length - 1));
  }

  for (final node in ast) {
    visit(node);
  }
  if (!supported) return null;
  final result = AttributedText(text.toString());
  for (final span in spans) {
    result.addAttribution(span.$1, SpanRange(span.$2, span.$3));
  }
  return result;
}

bool _sameListKind(DocumentNode first, DocumentNode second) =>
    (first is ListItemNode &&
        second is ListItemNode &&
        first.type == second.type) ||
    (first is TaskNode && second is TaskNode);

String _serializeNode(DocumentNode node) {
  if (node is OpaqueMarkdownNode) return node.source;
  if (node is HorizontalRuleNode) return '---';
  if (node is! TextNode)
    throw StateError('Unsupported document node ${node.runtimeType}');
  if (node.getMetadataValue('blockType') == codeAttribution) {
    final text = node.text.toPlainText();
    var fenceLength = 3;
    for (final match in RegExp(r'`+').allMatches(text)) {
      if (match.group(0)!.length >= fenceLength)
        fenceLength = match.group(0)!.length + 1;
    }
    final fence = '`' * fenceLength;
    final language = node.getMetadataValue('language') as String? ?? '';
    return '$fence$language\n$text\n$fence';
  }
  final text = _serializeInline(node.text);
  if (node is TaskNode) return '- [${node.isComplete ? 'x' : ' '}] $text';
  if (node is ListItemNode)
    return node.type == ListItemType.ordered
        ? '${node.getMetadataValue('ordinal') ?? 1}. $text'
        : '- $text';
  final type = node.getMetadataValue('blockType');
  if (type == blockquoteAttribution)
    return text.split('\n').map((line) => '> $line').join('\n');
  if (type is NamedAttribution && RegExp(r'^header[1-6]$').hasMatch(type.id))
    return '${'#' * int.parse(type.id.substring(6))} $text';
  return text;
}

String _serializeInline(AttributedText text) {
  final plain = text.toPlainText();
  final typedWikiTokens = <int, int>{};
  for (final match in _wikiToken.allMatches(plain)) {
    if (match.start > 0 && plain[match.start - 1] == '!') continue;
    var literal = false;
    for (var i = match.start; i < match.end; i++) {
      if (text.getAllAttributionsAt(i).contains(_literalWikiLinkAttribution) ||
          text.getAllAttributionsAt(i).contains(codeAttribution)) {
        literal = true;
        break;
      }
    }
    if (!literal) typedWikiTokens[match.start] = match.end;
  }
  String render(int start, int limit, Set<Attribution> enclosing) {
    final output = StringBuffer();
    var index = start;
    while (index < limit) {
      final styles = text.getAllAttributionsAt(index).difference(enclosing);
      final links = styles.whereType<LinkAttribution>();
      final Attribution? style = links.isNotEmpty
          ? links.first
          : styles.contains(boldAttribution)
          ? boldAttribution
          : styles.contains(italicsAttribution)
          ? italicsAttribution
          : styles.contains(codeAttribution)
          ? codeAttribution
          : null;
      if (style == null) {
        final wikiEnd = typedWikiTokens[index];
        if (wikiEnd != null && wikiEnd <= limit) {
          output.write(plain.substring(index, wikiEnd));
          index = wikiEnd;
          continue;
        }
        output.write(_escapeInline(plain.substring(index, index + 1)));
        index++;
        continue;
      }
      var end = index + 1;
      while (end < limit && text.getAllAttributionsAt(end).contains(style)) {
        end++;
      }
      if (style == codeAttribution) {
        output.write(_inlineCode(plain.substring(index, end)));
      } else if (style is LinkAttribution) {
        final body = render(index, end, {...enclosing, style});
        final destination = style.plainTextUri
            .replaceAll('\\', '%5C')
            .replaceAll(' ', '%20')
            .replaceAll('(', '%28')
            .replaceAll(')', '%29')
            .replaceAll('<', '%3C')
            .replaceAll('>', '%3E')
            .replaceAll('\n', '%0A');
        output.write('[$body]($destination)');
      } else {
        var contentStart = index;
        var contentEnd = end;
        while (contentStart < end && plain[contentStart].trim().isEmpty) {
          contentStart++;
        }
        while (contentEnd > contentStart &&
            plain[contentEnd - 1].trim().isEmpty) {
          contentEnd--;
        }
        output.write(plain.substring(index, contentStart));
        if (contentEnd > contentStart) {
          final delimiter = style == boldAttribution ? '**' : '*';
          output.write(
            '$delimiter${render(contentStart, contentEnd, {...enclosing, style})}$delimiter',
          );
        }
        output.write(plain.substring(contentEnd, end));
      }
      index = end;
    }
    return output.toString();
  }

  return render(0, plain.length, {})
      .replaceAllMapped(
        RegExp(r'(^|\n)([ \t]{4,}|\t[ \t]*)'),
        (match) =>
            '${match.group(1)}${match.group(2)!.replaceAll(' ', '&#32;').replaceAll('\t', '&#9;')}',
      )
      .replaceAllMapped(
        RegExp(r'(^|\n)([ \t]*)(\d+)([.)])(?=\s)'),
        (match) =>
            '${match.group(1)}${match.group(2)}${match.group(3)}\\${match.group(4)}',
      );
}

String _escapeInline(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAllMapped(
      RegExp(r'[\\`*_\[\]<>#|~+=-]'),
      (match) => '\\${match.group(0)}',
    );

String _inlineCode(String body) {
  var count = 1;
  for (final match in RegExp(r'`+').allMatches(body)) {
    if (match.group(0)!.length >= count) count = match.group(0)!.length + 1;
  }
  final ticks = '`' * count;
  final pad =
      body.startsWith('`') ||
          body.endsWith('`') ||
          (body.startsWith(' ') && body.endsWith(' ') && body.trim().isNotEmpty)
      ? ' '
      : '';
  return '$ticks$pad$body$pad$ticks';
}

Map<String, dynamic> _freezeMetadata(Map<String, dynamic> values) =>
    Map.unmodifiable(
      values.map((key, value) => MapEntry(key, _freezeValue(value))),
    );

dynamic _freezeValue(dynamic value) {
  if (value is Map)
    return Map.unmodifiable(
      value.map((key, item) => MapEntry(key, _freezeValue(item))),
    );
  if (value is List) return List.unmodifiable(value.map(_freezeValue));
  if (value is Set) return Set.unmodifiable(value.map(_freezeValue));
  return value;
}

class _WikiLinkSyntax extends md.InlineSyntax {
  _WikiLinkSyntax() : super(_wikiToken.pattern, startCharacter: 91);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('wiki-link', match.group(0)!));
    return true;
  }
}

class _EscapedWikiLinkSyntax extends md.InlineSyntax {
  _EscapedWikiLinkSyntax()
    : super(r'\\\[\\\[([^\r\n]*?)(?:\\\]\\\]|$)', startCharacter: 92);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final closed = match.group(0)!.endsWith(r'\]\]');
    parser.addNode(
      md.Element('literal-wiki-link', [
        md.Text('[['),
        ...md.Document(encodeHtml: false).parseInline(match.group(1)!),
        if (closed) md.Text(']]'),
      ]),
    );
    return true;
  }
}
