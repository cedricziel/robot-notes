import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ulid/ulid.dart';

String _hash(String source) => sha256.convert(utf8.encode(source)).toString();

/// Persistent identity and UTF-16 source span within one accepted body.
class MarkdownBlock {
  /// Creates a block whose offsets exclude surrounding blank lines.
  const MarkdownBlock({
    required this.id,
    required this.revision,
    required this.kind,
    required this.start,
    required this.end,
    required this.hash,
  });

  /// Loads accepted sidecar metadata.
  factory MarkdownBlock.fromJson(Map<String, dynamic> json) => MarkdownBlock(
        id: json['id'] as String,
        revision: json['revision'] as int,
        kind: json['kind'] as String,
        start: json['start'] as int,
        end: json['end'] as int,
        hash: json['hash'] as String,
      );

  /// Opaque identity, independent of content and position.
  final String id;

  /// Monotonically increasing revision for this identity.
  final int revision;

  /// Conservative top-level Markdown construct classification.
  final String kind;

  /// Inclusive UTF-16 offset in the accepted body.
  final int start;

  /// Exclusive UTF-16 offset in the accepted body.
  final int end;

  /// Exact span hash used only to verify freshness.
  final String hash;

  /// Returns exact source text from the accepted body.
  String source(String body) => body.substring(start, end);

  /// Serializes accepted sidecar metadata without inserting Markdown markers.
  Map<String, Object?> toJson() => {
        'id': id,
        'revision': revision,
        'kind': kind,
        'start': start,
        'end': end,
        'hash': hash,
      };
}

/// Block metadata and anchor invalidations for one accepted note revision.
class MarkdownBlockMap {
  /// Creates an accepted map.
  const MarkdownBlockMap({
    required this.version,
    required this.contentHash,
    required this.blocks,
    this.changedIds = const [],
    this.retiredIds = const [],
    this.ambiguousIds = const [],
  });

  /// Loads a retained accepted map.
  factory MarkdownBlockMap.fromJson(Map<String, dynamic> json) =>
      MarkdownBlockMap(
        version: json['version'] as int,
        contentHash: json['content_hash'] as String,
        blocks: [
          for (final block in json['blocks'] as List<dynamic>)
            MarkdownBlock.fromJson(block as Map<String, dynamic>),
        ],
        changedIds: (json['changed_ids'] as List<dynamic>).cast<String>(),
        retiredIds: (json['retired_ids'] as List<dynamic>).cast<String>(),
        ambiguousIds: (json['ambiguous_ids'] as List<dynamic>).cast<String>(),
      );

  /// Accepted whole-note version associated with this map.
  final int version;

  /// Hash of the full accepted body, including unmapped whitespace.
  final String contentHash;

  /// Source-ordered accepted blocks.
  final List<MarkdownBlock> blocks;

  /// Retained identities whose block revisions increased.
  final List<String> changedIds;

  /// Prior identities no longer present in the accepted body.
  final List<String> retiredIds;

  /// Prior identities requiring re-review because correspondence is uncertain.
  final List<String> ambiguousIds;

  /// Returns whether all spans and hashes refer to this exact accepted body.
  bool matches(String body) =>
      contentHash == _hash(body) &&
      blocks.every(
        (b) =>
            b.start >= 0 &&
            b.end >= b.start &&
            b.end <= body.length &&
            b.hash == _hash(b.source(body)),
      );

  /// Serializes the retained map and explicit anchor invalidations.
  Map<String, Object?> toJson() => {
        'version': version,
        'content_hash': contentHash,
        'offset_encoding': 'utf-16',
        'blocks': [for (final block in blocks) block.toJson()],
        'changed_ids': changedIds,
        'retired_ids': retiredIds,
        'ambiguous_ids': ambiguousIds,
      };
}

/// Reconciles exact spans without guessing ambiguous Markdown correspondence.
class MarkdownBlockReconciler {
  /// Uses opaque ULIDs unless a deterministic test generator is supplied.
  MarkdownBlockReconciler({String Function()? idGenerator})
      : _idGenerator = idGenerator ?? (() => Ulid().toString());

  final String Function() _idGenerator;

  /// Derives identities against a verified accepted base, preserving [source].
  /// Edited singleton blocks retain identity only between identical anchors.
  MarkdownBlockMap reconcile(
    String source, {
    required int version,
    MarkdownBlockMap? previous,
    String? previousSource,
  }) {
    final spans = _parse(source);
    final valid = previous != null &&
        previousSource != null &&
        previous.matches(previousSource);
    final old = valid ? previous.blocks : <MarkdownBlock>[];
    final matches = <int, MarkdownBlock>{};
    final changed = <String>[];
    final ambiguous = <String>{};
    if (valid && previousSource == source) {
      return MarkdownBlockMap(
        version: version,
        contentHash: _hash(source),
        blocks: old,
      );
    }
    final oldByText = <String, List<MarkdownBlock>>{};
    for (final block in old) {
      final key = '${block.kind}\u0000${block.source(previousSource!)}';
      (oldByText[key] ??= []).add(block);
    }
    final newByText = <String, List<int>>{};
    for (var i = 0; i < spans.length; i++) {
      final span = spans[i];
      final key = '${span.kind}\u0000${source.substring(span.start, span.end)}';
      (newByText[key] ??= []).add(i);
    }
    for (final entry in oldByText.entries) {
      final candidates = newByText[entry.key] ?? [];
      if (entry.value.length == 1 && candidates.length == 1) {
        matches[candidates.single] = entry.value.single;
      } else if (entry.value.length > 1 || candidates.length > 1) {
        ambiguous.addAll(entry.value.map((b) => b.id));
      }
    }
    final matchedIds = matches.values.map((b) => b.id).toSet();
    final matchedOld = {
      for (var i = 0; i < old.length; i++)
        if (matchedIds.contains(old[i].id)) i: old[i].id,
    };
    final matchedNew = {
      for (final entry in matches.entries) entry.key: entry.value.id,
    };
    final oldIntervals = _intervals(old.length, matchedOld);
    final newIntervals = _intervals(spans.length, matchedNew);
    for (final entry in oldIntervals.entries) {
      final candidates = newIntervals[entry.key] ?? [];
      final oldIndices = entry.value;
      if (oldIndices.length != 1 || candidates.length != 1) {
        if (candidates.isNotEmpty) {
          ambiguous.addAll(oldIndices.map((i) => old[i].id));
        }
        continue;
      }
      final prior = old[oldIndices.single];
      final index = candidates.single;
      final span = spans[index];
      if (ambiguous.contains(prior.id) ||
          !{'heading', 'paragraph', 'thematic'}.contains(span.kind) ||
          span.kind != prior.kind) {
        ambiguous.add(prior.id);
        continue;
      }
      matches[index] = prior;
      changed.add(prior.id);
    }
    final retained = matches.values.map((b) => b.id).toSet();
    final retired = [
      for (final block in previous?.blocks ?? <MarkdownBlock>[])
        if (!retained.contains(block.id)) block.id,
    ];
    if (!valid && previous != null) ambiguous.addAll(retired);
    return MarkdownBlockMap(
      version: version,
      contentHash: _hash(source),
      blocks: [
        for (var i = 0; i < spans.length; i++)
          MarkdownBlock(
            id: matches[i]?.id ?? _idGenerator(),
            revision: matches[i] == null
                ? 1
                : matches[i]!.revision +
                    (changed.contains(matches[i]!.id) ? 1 : 0),
            kind: spans[i].kind,
            start: spans[i].start,
            end: spans[i].end,
            hash: _hash(source.substring(spans[i].start, spans[i].end)),
          ),
      ],
      changedIds: changed,
      retiredIds: retired,
      ambiguousIds: ambiguous.toList(),
    );
  }
}

Map<String, List<int>> _intervals(int length, Map<int, String> anchors) {
  final result = <String, List<int>>{};
  String? before;
  final positions = anchors.keys.toList()..sort();
  var next = 0;
  for (var i = 0; i < length; i++) {
    if (anchors.containsKey(i)) {
      before = anchors[i];
      next++;
      continue;
    }
    final after = next < positions.length ? anchors[positions[next]] : null;
    (result['${before ?? "^"}\u0000${after ?? r"$"}'] ??= []).add(i);
  }
  return result;
}

class _Span {
  const _Span(this.kind, this.start, this.end);
  final String kind;
  final int start;
  final int end;
}

class _Line {
  const _Line(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
  bool get blank => text.trim().isEmpty;
}

final _heading = RegExp(r'^ {0,3}#{1,6}(?:\s|$)');
final _thematic =
    RegExp(r'^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$');
final _fence = RegExp('^ {0,3}(`{3,}|~{3,})');
final _list = RegExp(r'^ {0,3}(?:[-+*]|[0-9]{1,9}[.)])\s');
final _quote = RegExp('^ {0,3}>');
final _table = RegExp(r'^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$');
final _setext = RegExp(r'^ {0,3}(?:=+|-+)\s*$');
final _embedded = RegExp(r'^ {0,3}(?:<|!\[\[|\[\^[^\]]+\]:|\{\{|:::)');

List<_Span> _parse(String source) {
  final lines = <_Line>[];
  var start = 0;
  while (start < source.length) {
    final newline = source.indexOf('\n', start);
    final end = newline < 0 ? source.length : newline + 1;
    var text = source.substring(start, newline < 0 ? end : newline);
    if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
    lines.add(_Line(text, start, end));
    start = end;
  }
  final result = <_Span>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].blank) {
      i++;
      continue;
    }
    final first = i;
    final text = lines[i].text;
    var kind = 'paragraph';
    final fence = _fence.firstMatch(text);
    if (_embedded.hasMatch(text)) {
      result.add(_Span('opaque', lines[i].start, source.length));
      break;
    } else if (fence != null) {
      kind = 'fence';
      final marker = fence.group(1)!;
      final closing =
          RegExp('^ {0,3}${RegExp.escape(marker[0])}{${marker.length},}\\s*\$');
      i++;
      while (i < lines.length) {
        final closes = closing.hasMatch(lines[i].text);
        i++;
        if (closes) break;
      }
    } else if (_heading.hasMatch(text) || _thematic.hasMatch(text)) {
      kind = _heading.hasMatch(text) ? 'heading' : 'thematic';
      i++;
    } else if (i + 1 < lines.length && _setext.hasMatch(lines[i + 1].text)) {
      kind = 'heading';
      i += 2;
    } else {
      if (_list.hasMatch(text)) kind = 'list';
      if (_quote.hasMatch(text)) kind = 'quote';
      if (text.startsWith('    ') || text.startsWith('\t')) kind = 'code';
      if (i + 1 < lines.length && _table.hasMatch(lines[i + 1].text)) {
        kind = 'table';
      }
      i++;
      while (i < lines.length) {
        if (lines[i].blank) {
          var next = i + 1;
          while (next < lines.length && lines[next].blank) {
            next++;
          }
          final continuation = next < lines.length &&
              ((kind == 'list' &&
                      (_list.hasMatch(lines[next].text) ||
                          lines[next].text.startsWith('  ') ||
                          lines[next].text.startsWith('\t'))) ||
                  (kind == 'quote' && _quote.hasMatch(lines[next].text)) ||
                  (kind == 'code' &&
                      (lines[next].text.startsWith('    ') ||
                          lines[next].text.startsWith('\t'))));
          if (!continuation) break;
          i = next + 1;
          continue;
        }
        final currentText = lines[i].text;
        final unindented =
            !currentText.startsWith(' ') && !currentText.startsWith('\t');
        if (kind != 'paragraph' &&
            unindented &&
            (_heading.hasMatch(currentText) ||
                _thematic.hasMatch(currentText) ||
                _fence.hasMatch(currentText) ||
                _embedded.hasMatch(currentText))) {
          break;
        }
        if (kind == 'paragraph' && _setext.hasMatch(lines[i].text)) {
          kind = 'heading';
          i++;
          break;
        }
        if (kind == 'paragraph' &&
            (_heading.hasMatch(lines[i].text) ||
                _thematic.hasMatch(lines[i].text) ||
                _fence.hasMatch(lines[i].text) ||
                _list.hasMatch(lines[i].text) ||
                _quote.hasMatch(lines[i].text) ||
                _embedded.hasMatch(lines[i].text))) {
          break;
        }
        i++;
      }
    }
    result.add(_Span(kind, lines[first].start, lines[i - 1].end));
  }
  return result;
}
