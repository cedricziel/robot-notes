import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

const String _delimiter = '---';

/// Thrown when a note file's frontmatter block is structurally invalid.
///
/// The metadata-index scan logs the file path and excludes the file (per
/// the `notes-storage` capability), so [message] should be a single-line
/// human-readable explanation suitable for a log line.
class FrontmatterFormatException implements Exception {
  /// Creates a frontmatter format error wrapping a human-readable [message].
  FrontmatterFormatException(this.message);

  /// Why the frontmatter is invalid.
  final String message;

  @override
  String toString() => 'FrontmatterFormatException: $message';
}

/// Parsed view of a markdown note: a metadata map plus its body text.
@immutable
class Frontmatter {
  /// Creates a frontmatter pair.
  const Frontmatter({required this.metadata, required this.body});

  /// Frontmatter key/value pairs in **insertion order**. The map is keyed by
  /// `String`; values are whatever the YAML loader produced (`String`,
  /// `int`, `double`, `bool`, `null`, `List<Object?>`, `Map<String, Object?>`).
  /// The Storage layer narrows the typed v1 fields (`id`, `title`,
  /// `version`, `created_at`, `updated_at`) and treats anything else as
  /// extension data to preserve verbatim.
  final Map<String, Object?> metadata;

  /// The note's markdown body, beginning at the first character after the
  /// closing `---` delimiter (and the newline that follows it). Body is
  /// stored verbatim — no trimming, no normalisation.
  final String body;
}

/// Splits [text] into a frontmatter map plus body.
///
/// If [text] does not begin with `---` followed by a YAML map and a closing
/// `---`, the metadata is empty and the body is the original [text]
/// unchanged. A frontmatter block whose YAML is malformed throws
/// [FrontmatterFormatException].
Frontmatter parseFrontmatter(String text) {
  if (!text.startsWith('$_delimiter\n')) {
    return Frontmatter(metadata: const {}, body: text);
  }

  final lines = text.split('\n');
  // Find the next line that is exactly `---`, after the opening one.
  var closingIdx = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i] == _delimiter) {
      closingIdx = i;
      break;
    }
  }
  if (closingIdx == -1) {
    throw FrontmatterFormatException(
      'Frontmatter opening delimiter found but no closing "---" line.',
    );
  }

  final yamlSource = lines.sublist(1, closingIdx).join('\n');
  final body = lines.sublist(closingIdx + 1).join('\n');

  if (yamlSource.trim().isEmpty) {
    return Frontmatter(metadata: const {}, body: body);
  }

  final dynamic loaded;
  try {
    loaded = loadYaml(yamlSource);
  } on YamlException catch (e) {
    throw FrontmatterFormatException(
      'Malformed YAML frontmatter: ${e.message}',
    );
  }

  if (loaded == null) {
    return Frontmatter(metadata: const {}, body: body);
  }
  if (loaded is! YamlMap) {
    throw FrontmatterFormatException(
      'Frontmatter root must be a YAML map (got ${loaded.runtimeType}).',
    );
  }

  return Frontmatter(metadata: _normaliseMap(loaded), body: body);
}

/// Emits [fm] back to a markdown source string.
///
/// When `fm.metadata` is empty the frontmatter block is omitted entirely
/// (the body is returned verbatim). Otherwise the emitted form is:
///
/// ```yaml
/// ---
/// key: value
/// ...
/// ---
/// <body>
/// ```
///
/// Strings are always double-quoted with embedded `"` and `\` escaped, so
/// no value can be confused with another YAML scalar type. Integers,
/// doubles, and booleans emit as bare scalars; `null` emits as `~`. Lists
/// and maps emit in block style. Insertion order of [Frontmatter.metadata]
/// is preserved.
String serializeFrontmatter(Frontmatter fm) {
  if (fm.metadata.isEmpty) return fm.body;
  final buf = StringBuffer()..writeln(_delimiter);
  for (final entry in fm.metadata.entries) {
    _emitKv(buf, entry.key, entry.value, indent: 0);
  }
  buf
    ..writeln(_delimiter)
    ..write(fm.body);
  return buf.toString();
}

void _emitKv(
  StringBuffer buf,
  String key,
  Object? value, {
  required int indent,
}) {
  final pad = ' ' * indent;
  if (value is List) {
    buf.writeln('$pad$key:');
    for (final item in value) {
      _emitListItem(buf, item, indent: indent + 2);
    }
    return;
  }
  if (value is Map) {
    buf.writeln('$pad$key:');
    value.forEach((k, v) {
      _emitKv(buf, k as String, v, indent: indent + 2);
    });
    return;
  }
  buf.writeln('$pad$key: ${_emitScalar(value)}');
}

void _emitListItem(StringBuffer buf, Object? item, {required int indent}) {
  final pad = ' ' * indent;
  if (item is List) {
    buf.writeln('$pad-');
    for (final inner in item) {
      _emitListItem(buf, inner, indent: indent + 2);
    }
    return;
  }
  if (item is Map) {
    var first = true;
    item.forEach((k, v) {
      if (first) {
        if (v is List || v is Map) {
          buf.writeln('$pad- $k:');
          if (v is List) {
            for (final inner in v) {
              _emitListItem(buf, inner, indent: indent + 4);
            }
          } else if (v is Map) {
            v.forEach((k2, v2) {
              _emitKv(buf, k2 as String, v2, indent: indent + 4);
            });
          }
        } else {
          buf.writeln('$pad- $k: ${_emitScalar(v)}');
        }
        first = false;
      } else {
        _emitKv(buf, k as String, v, indent: indent + 2);
      }
    });
    return;
  }
  buf.writeln('$pad- ${_emitScalar(item)}');
}

String _emitScalar(Object? value) {
  if (value == null) return '~';
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) return value.toString();
  if (value is String) return _quoteString(value);
  throw FrontmatterFormatException(
    'Unsupported frontmatter value type: ${value.runtimeType}',
  );
}

String _quoteString(String s) {
  final escaped = s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

Map<String, Object?> _normaliseMap(YamlMap map) {
  final out = <String, Object?>{};
  for (final entry in map.nodes.entries) {
    final keyNode = entry.key;
    if (keyNode is! YamlScalar || keyNode.value is! String) {
      throw FrontmatterFormatException(
        'Frontmatter map keys must be strings (got ${keyNode.runtimeType}).',
      );
    }
    out[keyNode.value as String] = _normaliseValue(entry.value);
  }
  return out;
}

Object? _normaliseValue(YamlNode node) {
  if (node is YamlScalar) return node.value;
  if (node is YamlList) {
    return [for (final n in node.nodes) _normaliseValue(n)];
  }
  if (node is YamlMap) return _normaliseMap(node);
  return node.value;
}
