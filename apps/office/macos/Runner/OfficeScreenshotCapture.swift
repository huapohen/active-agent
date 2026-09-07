import Cocoa
import CoreGraphics

struct OfficeScreenshotFailure: Error {
  let code: String
  let message: String
}

struct OfficeScreenshotOptions {
  let hideWindow: Bool

  init(arguments: Any?) throws {
    guard let arguments = arguments else {
      hideWindow = false
      return
    }
    guard let fields = arguments as? [String: Any],
      fields.keys.allSatisfy({ $0 == "hide_window" }) else {
      throw OfficeScreenshotFailure(code: "invalid_arguments", message: "截图仅支持隐藏当前窗口选项。")
    }
    if let value = fields["hide_window"] {
      guard let number = value as? NSNumber,
        CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw OfficeScreenshotFailure(code: "invalid_arguments", message: "隐藏窗口选项必须为布尔值。")
      }
      hideWindow = number.boolValue
    } else {
      hideWindow = false
    }
  }
}

struct OfficeScreenshotImage {
  let filename: String
  let bytes: Data
}

/// A user-operated system region picker. No display is captured automatically,
/// and no screenshot is uploaded or retained by this platform adapter.
final class OfficeScreenshotCapture {
  static let maximumBytes = 12 * 1024 * 1024
  static let executable = URL(fileURLWithPath: "/usr/sbin/screencapture")
  private var process: Process?

  var enabled: Bool {
    (Bundle.main.object(forInfoDictionaryKey: "RenjiScreenshotEnabled") as? Bool) ?? true
  }

  var available: Bool {
    enabled && FileManager.default.isExecutableFile(atPath: Self.executable.path)
  }

  var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }

  func requestPermission() -> Bool {
    guard available else { return false }
    return CGRequestScreenCaptureAccess()
  }

  static func readOutput(
    at file: URL, exitStatus: Int32, hasErrorOutput: Bool, permissionGranted: Bool
  ) throws -> Data? {
    let exists = FileManager.default.fileExists(atPath: file.path)
    if !exists && exitStatus == 1 && !hasErrorOutput && permissionGranted {
      return nil // Escape cancels the system interactive selection.
    }
    guard permissionGranted else {
      throw OfficeScreenshotFailure(
        code: "permission_required", message: "请在系统设置中允许人机录制屏幕，然后重启人机并重试。")
    }
    guard exists, exitStatus == 0 else {
      throw OfficeScreenshotFailure(
        code: exitStatus == 0 && !exists ? "clipboard_only" : "capture_failed",
        message: exitStatus == 0 && !exists
          ? "截图未返回文件。若按住了 Control，图片已进入剪贴板；请松开 Control 后重新截取。"
          : "系统截图未完成，请重新选择截图区域。")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw OfficeScreenshotFailure(code: "invalid_image", message: "系统截图没有返回有效图片。")
    }
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0, size <= maximumBytes else {
      throw OfficeScreenshotFailure(code: "image_too_large", message: "截图需小于 12 MB，请选择更小的区域。")
    }
    let bytes = try Data(contentsOf: file)
    guard bytes.count <= maximumBytes,
      bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
      let bitmap = NSBitmapImageRep(data: bytes), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
      throw OfficeScreenshotFailure(code: "invalid_image", message: "系统截图没有返回有效 PNG 图片。")
    }
    return bytes
  }

  func capture(
    options: OfficeScreenshotOptions,
    completion: @escaping (Result<OfficeScreenshotImage?, OfficeScreenshotFailure>) -> Void
  ) {
    guard available else {
      completion(.failure(OfficeScreenshotFailure(code: "unavailable", message: "当前设备未启用系统截图。")))
      return
    }
    guard process == nil else {
      completion(.failure(OfficeScreenshotFailure(code: "capture_busy", message: "请先完成或取消正在进行的截图。")))
      return
    }
    guard permissionGranted else {
      completion(.failure(OfficeScreenshotFailure(
        code: "permission_required", message: "截图需要系统屏幕录制权限，请授权后重启人机。")))
      return
    }
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("renji-screenshot-" + UUID().uuidString, isDirectory: true)
    let file = folder.appendingPathComponent("capture.png")
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    } catch {
      completion(.failure(OfficeScreenshotFailure(code: "temporary_storage", message: "无法创建本机截图临时目录。")))
      return
    }
    let restoreWindow = options.hideWindow && !NSApp.isHidden
    let task = Process()
    let errors = Pipe()
    task.executableURL = Self.executable
    // Explicit mouse region selection; never clipboard, auto-upload or an
    // external image editor. Escape is handled by the system picker itself.
    task.arguments = ["-i", "-s", "-x", "-t", "png", file.path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = errors
    process = task
    task.terminationHandler = { [weak self] completed in
      let errorData = errors.fileHandleForReading.readDataToEndOfFile()
      var result: Result<OfficeScreenshotImage?, OfficeScreenshotFailure>
      do {
        let bytes = try Self.readOutput(
          at: file, exitStatus: completed.terminationStatus, hasErrorOutput: !errorData.isEmpty,
          permissionGranted: CGPreflightScreenCaptureAccess())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        result = .success(bytes.map {
          OfficeScreenshotImage(filename: "截图-" + formatter.string(from: Date()) + ".png", bytes: $0)
        })
      } catch let failure as OfficeScreenshotFailure {
        result = .failure(failure)
      } catch {
        result = .failure(OfficeScreenshotFailure(code: "capture_failed", message: "无法读取系统截图，请重试。"))
      }
      try? FileManager.default.removeItem(at: folder)
      DispatchQueue.main.async {
        self?.process = nil
        if restoreWindow {
          NSApp.unhide(nil)
          NSApp.activate(ignoringOtherApps: true)
        }
        completion(result)
      }
    }
    if restoreWindow { NSApp.hide(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + (restoreWindow ? 0.15 : 0)) {
      do {
        try task.run()
      } catch {
        self.process = nil
        try? FileManager.default.removeItem(at: folder)
        if restoreWindow {
          NSApp.unhide(nil)
          NSApp.activate(ignoringOtherApps: true)
        }
        completion(.failure(OfficeScreenshotFailure(code: "capture_unavailable", message: "当前环境无法启动系统截图。")))
      }
    }
  }
}
