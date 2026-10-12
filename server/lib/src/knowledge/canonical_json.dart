import 'dart:convert';

/// Stable JSON map ordering; array order and exact string content remain
/// intact.
String canonicalKnowledgeJson(Object? value) => jsonEncode(_ordered(value));

Object? _ordered(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List<Object?>) return value.map(_ordered).toList();
  return value;
}
