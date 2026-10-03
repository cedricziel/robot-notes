// Driver for `flutter drive --driver=test_driver/integration_test.dart
// --target=integration_test/screenshot_test.dart`. `onScreenshot` writes
// each captured PNG to disk on the host running `flutter drive` (this is
// how iOS/macOS screenshots reach the fastlane lane — no need to fish them
// out of an Xcode test result bundle).
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final outputDir = Platform.environment['SCREENSHOT_OUTPUT_DIR'];
  // Distinguishes iPhone/iPad/Mac captures sharing one output directory
  // (see app/fastlane/lib/screenshot_capture.rb) — e.g. "iphone" turns
  // "01_notes_list" into "iphone_01_notes_list.png".
  final prefix = Platform.environment['SCREENSHOT_PREFIX'];
  await integrationDriver(
    onScreenshot:
        (
          String screenshotName,
          List<int> screenshotBytes, [
          Map<String, Object?>? args,
        ]) async {
          final fileName = prefix == null
              ? '$screenshotName.png'
              : '${prefix}_$screenshotName.png';
          if (outputDir == null) {
            await File(fileName).writeAsBytes(screenshotBytes);
            return true;
          }
          await Directory(outputDir).create(recursive: true);
          final path = '$outputDir${Platform.pathSeparator}$fileName';
          await File(path).writeAsBytes(screenshotBytes);
          return true;
        },
  );
}
