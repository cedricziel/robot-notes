import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:meta/meta.dart';

/// A file chosen via the platform's native file picker: its display name
/// and raw bytes.
@immutable
class PickedFile {
  /// Creates a picked file.
  const PickedFile({required this.name, required this.bytes});

  /// The file's name, including extension, as the platform reported it.
  final String name;

  /// The file's full contents.
  final Uint8List bytes;
}

/// Opens the platform file picker and returns the chosen file, or `null`
/// if the user cancelled. Exists as its own function type — rather than
/// calling `FilePicker.pickFile()` directly wherever a file is needed —
/// so a caller can inject a fake picker in a widget test instead of
/// driving a real native dialog.
typedef PickFile = Future<PickedFile?> Function();

/// The production [PickFile] implementation, backed by `package:file_picker`.
Future<PickedFile?> pickFileViaFilePicker() async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;
  return PickedFile(name: file.name, bytes: await file.readAsBytes());
}
