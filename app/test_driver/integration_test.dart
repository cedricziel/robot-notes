// Driver for `flutter drive --driver=test_driver/integration_test.dart
// --target=integration_test/screenshot_test.dart`. `onScreenshot` writes
// each captured PNG to disk on the host running `flutter drive` (this is
// how iOS/macOS screenshots reach the fastlane lane — no need to fish them
// out of an Xcode test result bundle).
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final outputDir = Platform.environment['SCREENSHOT_OUTPUT_DIR'];
  await integrationDriver(
    onScreenshot:
        (
          String screenshotName,
          List<int> screenshotBytes, [
          Map<String, Object?>? args,
        ]) async {
          if (outputDir == null) {
            await File('$screenshotName.png').writeAsBytes(screenshotBytes);
            return true;
          }
          await Directory(outputDir).create(recursive: true);
          final path = '$outputDir${Platform.pathSeparator}$screenshotName.png';
          await File(path).writeAsBytes(screenshotBytes);
          return true;
        },
  );
}
