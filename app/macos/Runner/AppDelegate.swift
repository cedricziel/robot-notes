import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // window_manager intercepts the close button and hides the window instead
    // of closing it (see TrayController), so this is a backstop for any close
    // path it doesn't catch: keep running with the tray icon rather than quit.
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
