/// Read-only operations over accepted data or authorized review metadata.
const knowledgeReadOperations = {
  'list_knowledge_types',
  'get_knowledge_type',
  'query_knowledge',
  'inspect_source',
  'get_knowledge_proposal',
  'get_knowledge_type_proposal',
  'extraction_health',
  'preview_schema_org',
  'preview_knowledge_type_upgrade',
};

/// Human decisions remain restricted by principal kind as well as this
/// capability.
const knowledgeReviewOperations = {
  'review_knowledge_proposal',
  'review_knowledge_type_proposal',
};

/// Transport scope selection; domain services enforce resource ACLs and human
/// roles.
String knowledgeOperationScope(String name) =>
    name == 'capabilities' || knowledgeReadOperations.contains(name)
        ? 'notes:read'
        : knowledgeReviewOperations.contains(name)
            ? 'knowledge:review'
            : name == 'purge_source_revision'
                ? 'knowledge:purge'
                : const {'configure_source_scope', 'reextract_source'}
                        .contains(name)
                    ? 'knowledge:policy'
                    : 'knowledge:propose';
