import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Moves files to the Trash the way Finder does, without needing
    // permission to script Finder.
    let files = FlutterMethodChannel(name: "stackyard/files", binaryMessenger: flutterViewController.engine.binaryMessenger)
    files.setMethodCallHandler { call, result in
      guard call.method == "trash", let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        result(nil)
      } catch {
        result(FlutterError(code: "trash", message: error.localizedDescription, details: nil))
      }
    }

    super.awakeFromNib()
  }

  // Starts hidden; Dart shows the window when it's ready, or keeps it in the
  // menu bar when Stackyard was started at login.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
