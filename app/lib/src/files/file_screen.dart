import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';

/// Saves authenticated file bytes, returning null when the user cancels.
typedef SaveFile = Future<Uri?> Function({
  required String filename,
  required String contentType,
  required Uint8List bytes,
});

/// Opens the platform save dialog with the file's original name and type.
Future<Uri?> saveFileViaFilePicker({
  required String filename,
  required String contentType,
  required Uint8List bytes,
}) => FilePicker.saveFile(
  fileName: filename,
  mimeType: contentType,
  bytes: bytes,
);

/// Displays vault file metadata and bounded image previews.
class FileScreen extends StatefulWidget {
  const FileScreen({
    required this.api,
    required this.relativePath,
    required this.onClose,
    this.saveFile = saveFileViaFilePicker,
    super.key,
  });

  final RobotNotesClient api;
  final String relativePath;
  final VoidCallback onClose;
  final SaveFile saveFile;

  @override
  State<FileScreen> createState() => _FileScreenState();
}

class _FileScreenState extends State<FileScreen> {
  static const _previewLimit = 10 * 1024 * 1024;
  VaultFile? _file;
  Uint8List? _preview;
  String? _error;
  String? _downloadError;
  bool _loading = true;
  bool _downloading = false;
  bool _previewTooLarge = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.relativePath != widget.relativePath) {
      _load();
    }
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _load() async {
    final generation = ++_generation;
    final api = widget.api;
    final relativePath = widget.relativePath;
    setState(() {
      _file = null;
      _preview = null;
      _error = null;
      _downloadError = null;
      _previewTooLarge = false;
      _loading = true;
      _downloading = false;
    });
    try {
      final separator = relativePath.lastIndexOf('/');
      final parent = separator < 0 ? '' : relativePath.substring(0, separator);
      final files = await api.listFiles(parent);
      if (!_isCurrent(generation)) return;
      final file = files
          .where((file) => file.relativePath == relativePath)
          .firstOrNull;
      if (file == null) throw const NotFoundException();
      setState(() => _file = file);
      if (file.contentType.startsWith('image/')) {
        if (file.size > _previewLimit) {
          _previewTooLarge = true;
        } else {
          try {
            final bytes = await api.getFile(
              relativePath,
              maxBytes: _previewLimit,
            );
            if (!_isCurrent(generation)) return;
            _preview = bytes;
          } on PayloadTooLargeException {
            if (!_isCurrent(generation)) return;
            _previewTooLarge = true;
          }
        }
      }
      if (_isCurrent(generation)) setState(() => _loading = false);
    } catch (error) {
      if (!_isCurrent(generation)) return;
      setState(() {
        _loading = false;
        _error = error is NotFoundException
            ? 'File not found.'
            : 'Could not load file.';
      });
    }
  }

  Future<void> _download() async {
    final file = _file;
    if (file == null || _downloading) return;
    final generation = _generation;
    final saveFile = widget.saveFile;
    setState(() {
      _downloading = true;
      _downloadError = null;
    });
    try {
      final bytes = await widget.api.getFile(file.relativePath);
      if (!_isCurrent(generation)) return;
      await saveFile(
        filename: file.filename,
        contentType: file.contentType,
        bytes: bytes,
      );
    } catch (_) {
      if (_isCurrent(generation)) {
        setState(() => _downloadError = 'Could not download file. Try again.');
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _downloading = false);
    }
  }

  Widget _failure(String message) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(message),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        children: [
          TextButton(onPressed: _load, child: const Text('Retry')),
          TextButton(onPressed: widget.onClose, child: const Text('Return')),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final file = _file;
    return Scaffold(
      appBar: AppBar(
        title: Text(file?.filename ?? widget.relativePath.split('/').last),
        leading: IconButton(
          tooltip: 'Close file',
          onPressed: widget.onClose,
          icon: const Icon(Icons.close),
        ),
      ),
      body: _loading && file == null
          ? const Center(child: CircularProgressIndicator.adaptive())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (file != null) ...[
                        Text(widget.relativePath),
                        const SizedBox(height: 8),
                        Text(file.contentType),
                        Text('${file.size} bytes'),
                        const SizedBox(height: 16),
                      ],
                      if (_loading)
                        const Center(
                          child: CircularProgressIndicator.adaptive(),
                        )
                      else if (_error != null)
                        _failure(_error!)
                      else if (_preview != null)
                        Image.memory(
                          _preview!,
                          fit: BoxFit.contain,
                          semanticLabel: file?.filename,
                          errorBuilder: (_, _, _) =>
                              _failure('Could not preview image.'),
                        )
                      else if (_previewTooLarge)
                        const Text('Image exceeds the 10 MiB preview limit.'),
                      if (file != null && !_loading) ...[
                        const SizedBox(height: 16),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            onPressed: _downloading ? null : _download,
                            icon: const Icon(Icons.download),
                            label: Text(
                              _downloading ? 'Downloading…' : 'Download',
                            ),
                          ),
                        ),
                        if (_downloadError != null) ...[
                          const SizedBox(height: 12),
                          Text(_downloadError!),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
