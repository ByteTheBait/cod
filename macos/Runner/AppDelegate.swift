import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var pendingFolder: String?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Called when the app is launched with a folder path (e.g. `Cod /path/to/dir`)
  // or when a folder is opened via Finder / "Open With".
  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first else { return }
    let path = url.path
    // If the Flutter engine is ready, forward immediately; otherwise stash it.
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      sendFolder(path, to: controller)
    } else {
      pendingFolder = path
    }
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Forward any folder that arrived before the engine was ready.
    if let pending = pendingFolder,
       let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      sendFolder(pending, to: controller)
      pendingFolder = nil
    }
  }

  private func sendFolder(_ path: String, to controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "cod/folder",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.invokeMethod("openFolder", arguments: path)
  }
}
