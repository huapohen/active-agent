import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class OfficeScreenshot {
  const OfficeScreenshot({required this.filename, required this.bytes});
  final String filename;
  final Uint8List bytes;
  String get mimeType => 'image/png';
}

class OfficeScreenshotCapability {
  const OfficeScreenshotCapability({
    required this.available,
    this.requiresPermission = false,
    this.reason = '',
  });
  final bool available;
  final bool requiresPermission;
  final String reason;
}

class OfficeScreenshotException implements Exception {
  const OfficeScreenshotException(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

/// Native capture is an explicit user selection, never a file-picker shortcut.
/// The caller decides whether/where to upload the returned local PNG and must
/// recheck its captured identity, room and draft after the async selection.
class OfficeScreenshotService {
  OfficeScreenshotService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('renji/native_screenshot');

  static const enabled = bool.fromEnvironment(
    'OFFICE_SCREENSHOT_ENABLED',
    defaultValue: true,
  );
  static const maximumBytes = 12 * 1024 * 1024;
  final MethodChannel _channel;

  bool get supported =>
      enabled && !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Future<OfficeScreenshotCapability> capability() async {
    if (!supported) {
      return const OfficeScreenshotCapability(
        available: false,
        reason: '当前平台尚未接入原生区域截图。',
      );
    }
    try {
      final value = await _channel.invokeMapMethod<String, Object?>(
        'capability',
      );
      if (value?['protocol'] != 'native-screenshot/v1' ||
          value?['available'] is! bool ||
          value?['requires_permission'] is! bool) {
        return const OfficeScreenshotCapability(
          available: false,
          reason: '截图组件版本不匹配，请重启最新客户端。',
        );
      }
      return OfficeScreenshotCapability(
        available: value!['available'] == true,
        requiresPermission: value['requires_permission'] == true,
        reason: value['reason'] is String ? value['reason'] as String : '',
      );
    } on MissingPluginException {
      return const OfficeScreenshotCapability(
        available: false,
        reason: '截图组件尚未加载，请重新构建并启动 macOS 客户端。',
      );
    } on PlatformException {
      return const OfficeScreenshotCapability(
        available: false,
        reason: '暂时无法读取系统截图能力。',
      );
    }
  }

  /// Invoke only following an explicit user gesture. macOS displays any
  /// permission request; this API cannot grant or bypass the user's consent.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      throw OfficeScreenshotException(
        error.code,
        error.message ?? '系统无法请求截图权限。',
      );
    }
  }

  /// Returns null only for a user-cancelled system selection.
  Future<OfficeScreenshot?> capture({bool hideWindow = false}) async {
    if (!supported) {
      throw const OfficeScreenshotException(
        'unsupported_platform',
        '当前平台尚未接入原生区域截图。',
      );
    }
    Map<String, Object?>? value;
    try {
      value = await _channel.invokeMapMethod<String, Object?>('capture', {
        'hide_window': hideWindow,
      });
    } on MissingPluginException {
      throw const OfficeScreenshotException(
        'native_unavailable',
        '截图组件尚未加载，请重新构建并启动 macOS 客户端。',
      );
    } on PlatformException catch (error) {
      throw OfficeScreenshotException(
        error.code,
        error.message ?? '系统截图失败，请重试。',
      );
    }
    if (value == null) return null;
    final filename = value['filename'], bytes = value['bytes'];
    if (filename is! String ||
        filename.isEmpty ||
        filename.length > 200 ||
        filename.contains(RegExp(r'[/\\\x00-\x1f]')) ||
        !filename.toLowerCase().endsWith('.png') ||
        value['mime_type'] != 'image/png' ||
        bytes is! Uint8List ||
        bytes.length < 8 ||
        bytes.length > maximumBytes ||
        !listEquals(bytes.take(8).toList(), [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ])) {
      throw const OfficeScreenshotException(
        'invalid_image',
        '系统没有返回有效的本机 PNG 截图。',
      );
    }
    return OfficeScreenshot(filename: filename, bytes: bytes);
  }
}
