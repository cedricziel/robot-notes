import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge/type_definition.dart';

/// Portable filesystem document for definitions, vocabulary, or adoption
/// records.
class KnowledgeTypeDocument {
  KnowledgeTypeDocument._(
    this.markdown,
    this.role,
    this.reference,
    this.definition,
  );

  /// Decodes reserved metadata without changing ordinary note fields or prose.
  factory KnowledgeTypeDocument.parse(String markdown) {
    final metadata = parseFrontmatter(markdown).metadata['knowledge'];
    if (metadata is! Map<String, Object?> ||
        metadata['format_version'] is! int ||
        metadata['format_version'] != 1) {
      throw const FormatException('Unsupported knowledge document format');
    }
    final role = metadata['role'];
    if (role == 'type_definition') {
      final definition = KnowledgeTypeDefinition.fromMetadata(metadata);
      return KnowledgeTypeDocument._(
        markdown,
        role! as String,
        definition.reference,
        definition,
      );
    }
    if (role == 'vocabulary_term') {
      final term = metadata['term'];
      if (term is! Map<String, Object?> ||
          term['kind'] is! String ||
          term['origin'] is! Map<String, Object?> ||
          term['definition'] is! Map<String, Object?>) {
        throw const FormatException('Invalid vocabulary term');
      }
      return KnowledgeTypeDocument._(
        markdown,
        role! as String,
        KnowledgeTypeReference.fromJson(term),
        null,
      );
    }
    if (role == 'ontology_adoption') {
      final adoption = metadata['adoption'];
      if (adoption is! Map<String, Object?> ||
          adoption['namespace'] is! String ||
          adoption['artifact_source'] is! String ||
          adoption['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(adoption['sha256']! as String) ||
          adoption['definitions'] is! List<Object?> ||
          adoption['dependencies'] is! List<Object?> ||
          adoption['unsupported_dispositions'] is! Map<String, Object?>) {
        throw const FormatException('Invalid adoption manifest');
      }
      for (final reference in adoption['definitions']! as List<Object?>) {
        KnowledgeTypeReference.fromJson(reference);
      }
      return KnowledgeTypeDocument._(
        markdown,
        role! as String,
        KnowledgeTypeReference(
          adoption['id']! as String,
          adoption['release'],
        ),
        null,
      );
    }
    throw const FormatException('Unsupported type document role');
  }

  /// Exact reviewed source, including ordinary frontmatter and body.
  final String markdown;

  /// Explicit role, independent of directory location.
  final String role;

  /// Stable identity and pinned revision of the document.
  final KnowledgeTypeReference reference;

  /// Enforced definition; other roles preserve vocabulary rather than constrain
  /// it.
  final KnowledgeTypeDefinition? definition;
}
