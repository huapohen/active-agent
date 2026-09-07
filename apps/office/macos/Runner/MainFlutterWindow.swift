import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let screenshotCapture = OfficeScreenshotCapture()
  private var screenshotChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "renji/native_screenshot", binaryMessenger: flutterViewController.engine.binaryMessenger)
    screenshotChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "capability":
        result([
          "protocol": "native-screenshot/v1", "available": self.screenshotCapture.available,
          "requires_permission": self.screenshotCapture.available && !self.screenshotCapture.permissionGranted,
          "interactive_region": true, "hide_window": true,
          "reason": self.screenshotCapture.available ? "" : "当前设备未启用系统截图。",
        ])
      case "requestPermission":
        result(self.screenshotCapture.requestPermission())
      case "capture":
        do {
          let options = try OfficeScreenshotOptions(arguments: call.arguments)
          self.screenshotCapture.capture(options: options) { outcome in
            switch outcome {
            case .success(let image):
              guard let image = image else { result(nil); return }
              result([
                "filename": image.filename, "mime_type": "image/png",
                "bytes": FlutterStandardTypedData(bytes: image.bytes),
              ])
            case .failure(let error):
              result(FlutterError(code: error.code, message: error.message, details: nil))
            }
          }
        } catch let error as OfficeScreenshotFailure {
          result(FlutterError(code: error.code, message: error.message, details: nil))
        } catch {
          result(FlutterError(code: "invalid_arguments", message: "截图参数无效。", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
