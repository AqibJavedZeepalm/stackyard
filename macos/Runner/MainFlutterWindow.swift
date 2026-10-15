import Cocoa
import FlutterMacOS
import UserNotifications
import window_manager

/// Notifications through UserNotifications (NSUserNotification is deprecated).
/// Clicking one tells Dart, which opens the window.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "stackyard/notify", binaryMessenger: messenger)
    super.init()
    UNUserNotificationCenter.current().delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setup":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
          DispatchQueue.main.async {
            if let error { result(FlutterError(code: "notify", message: error.localizedDescription, details: nil)) } else { result(granted) }
          }
        }
      case "show":
        let args = call.arguments as? [String: String] ?? [:]
        self?.show(title: args["title"] ?? "", body: args["body"] ?? "") { error in
          DispatchQueue.main.async {
            result(error.map { FlutterError(code: "notify", message: $0.localizedDescription, details: nil) })
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func show(title: String, body: String, done: @escaping (Error?) -> Void) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: done)
  }

  // Show it even while Stackyard is in front.
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    channel.invokeMethod("clicked", arguments: nil)
    completionHandler()
  }
}

class MainFlutterWindow: NSWindow {
  private var notifier: Notifier?

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

    notifier = Notifier(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  // Starts hidden; Dart shows the window when it's ready, or keeps it in the
  // menu bar when Stackyard was started at login.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
