import Cocoa

var checks = 0
func verify(_ condition: Bool, _ label: String) {
  precondition(condition, label)
  checks += 1
}
func rejects(_ code: String, _ action: () throws -> Void) {
  do {
    try action()
    preconditionFailure("Expected " + code)
  } catch let error as OfficeScreenshotFailure {
    verify(error.code == code, "Unexpected native failure code")
  } catch {
    preconditionFailure("Unexpected error type")
  }
}

verify(try OfficeScreenshotOptions(arguments: nil).hideWindow == false, "Default visible window")
verify(try OfficeScreenshotOptions(arguments: [String: Any]()).hideWindow == false, "Empty options")
verify(try OfficeScreenshotOptions(arguments: ["hide_window": true]).hideWindow, "Native hidden-window option")
for invalid: Any in [["hide_window": 1], ["hide_window": "true"], ["path": "/tmp/other.png"], ["hide_window"]] {
  rejects("invalid_arguments") { _ = try OfficeScreenshotOptions(arguments: invalid) }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("renji-screenshot-checks-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let output = directory.appendingPathComponent("capture.png")
verify(try OfficeScreenshotCapture.readOutput(at: output, exitStatus: 1, hasErrorOutput: false, permissionGranted: true) == nil, "Escape cancellation")
rejects("capture_failed") { _ = try OfficeScreenshotCapture.readOutput(at: output, exitStatus: 1, hasErrorOutput: true, permissionGranted: true) }
rejects("permission_required") { _ = try OfficeScreenshotCapture.readOutput(at: output, exitStatus: 1, hasErrorOutput: false, permissionGranted: false) }
rejects("clipboard_only") { _ = try OfficeScreenshotCapture.readOutput(at: output, exitStatus: 0, hasErrorOutput: false, permissionGranted: true) }
try Data("Not a screenshot".utf8).write(to: output)
rejects("invalid_image") { _ = try OfficeScreenshotCapture.readOutput(at: output, exitStatus: 0, hasErrorOutput: false, permissionGranted: true) }
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: output)
verify(try OfficeScreenshotCapture.readOutput(at: output, exitStatus: 0, hasErrorOutput: false, permissionGranted: true) == png, "Real PNG bytes preserved")
rejects("capture_failed") { _ = try OfficeScreenshotCapture.readOutput(at: output, exitStatus: 2, hasErrorOutput: false, permissionGranted: true) }
try Data(count: OfficeScreenshotCapture.maximumBytes + 1).write(to: output)
rejects("image_too_large") { _ = try OfficeScreenshotCapture.readOutput(at: output, exitStatus: 0, hasErrorOutput: false, permissionGranted: true) }
print("Native screenshot checks: \(checks) passed; no capture or permission UI invoked.")
