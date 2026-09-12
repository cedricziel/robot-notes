import 'package:app/src/notes/save_shortcut.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('installWebSaveShortcut resolves to a callable no-op off web '
      '(the web implementation itself only runs in a browser; see the PR '
      'description for the Chrome verification of the Cmd+S/Ctrl+S fix)', () {
    var saveCount = 0;
    final uninstall = installWebSaveShortcut(() => saveCount++);

    expect(saveCount, 0);
    uninstall();
    expect(saveCount, 0);
  });
}
