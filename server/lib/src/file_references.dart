import 'package:markdown/markdown.dart' as markdown;

/// Resolves rendered Markdown links and images to canonical vault file paths.
Set<String> vaultFileReferences(String content, String notePath) {
  final paths = <String>{};
  final base =
      Uri(path: '/notes/files/${notePath.isEmpty ? '' : '$notePath/'}');
  void visit(markdown.Node node) {
    if (node is! markdown.Element) return;
    final raw = node.attributes['href'] ?? node.attributes['src'];
    if (raw != null) {
      try {
        final resolved = base.resolve(raw);
        final decoded = Uri.decodeComponent(resolved.path);
        final path =
            Uri.decodeComponent(Uri(path: decoded).normalizePath().path);
        final relative = path.startsWith('/notes/files/')
            ? path.substring('/notes/files/'.length)
            : path.startsWith('/')
                ? path.substring(1)
                : path;
        if (relative.isNotEmpty) paths.add(relative);
      } on FormatException {
        // An invalid URI cannot address a published file.
      }
    }
    for (final child in node.children ?? const <markdown.Node>[]) {
      visit(child);
    }
  }

  final document =
      markdown.Document(extensionSet: markdown.ExtensionSet.gitHubWeb);
  for (final node in document.parseLines(content.split('\n'))) {
    visit(node);
  }
  return paths;
}
