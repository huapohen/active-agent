import 'package:active_office/office_screenshot.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('renji/native_screenshot');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = OfficeScreenshotService(channel: channel);
  final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1]);
  Map<String, Object?> image() => {
    'filename': '截图.png',
    'mime_type': 'image/png',
    'bytes': png,
  };
  Matcher failure(String code) => isA<OfficeScreenshotException>().having(
    (error) => error.code,
    'code',
    code,
  );

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'unsupported platforms never invoke native capture or consent',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async => calls++);
      expect(service.supported, false);
      expect((await service.capability()).available, false);
      expect(await service.requestPermission(), false);
      await expectLater(
        service.capture(),
        throwsA(failure('unsupported_platform')),
      );
      expect(calls, 0);
    },
  );

  test('capability reads permission without requesting consent', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return {
        'protocol': 'native-screenshot/v1',
        'available': true,
        'requires_permission': true,
        'interactive_region': true,
        'hide_window': true,
      };
    });
    final capability = await service.capability();
    expect(capability.available, true);
    expect(capability.requiresPermission, true);
    expect(calls, ['capability']);
  });

  test('explicit permission request preserves a user denial', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'requestPermission');
      return false;
    });
    expect(await service.requestPermission(), false);
  });

  test('capture returns local PNG and passes hide-window selection', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'capture');
      expect(call.arguments, {'hide_window': true});
      return image();
    });
    final captured = await service.capture(hideWindow: true);
    expect(captured?.filename, '截图.png');
    expect(captured?.bytes, png);
    expect(captured?.mimeType, 'image/png');
  });

  test('user cancellation returns null without any attachment', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await service.capture(), isNull);
  });

  test('permission, busy and native failures remain explicit', () async {
    for (final code in [
      'permission_required',
      'capture_busy',
      'capture_failed',
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code, message: '系统未完成截图');
      });
      await expectLater(service.capture(), throwsA(failure(code)));
    }
  });

  test('missing native component is unavailable, not cancellation', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect((await service.capability()).available, false);
    await expectLater(
      service.capture(),
      throwsA(failure('native_unavailable')),
    );
  });

  test('rejects paths, non-PNG bytes and oversized platform output', () async {
    for (final invalid in [
      {...image(), 'filename': '../private.png'},
      {...image(), 'filename': r'C:\private.png'},
      {...image(), 'filename': 'bad\nname.png'},
      {...image(), 'mime_type': 'image/jpeg'},
      {...image(), 'bytes': Uint8List(20)},
      {
        ...image(),
        'bytes': Uint8List(OfficeScreenshotService.maximumBytes + 1),
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => invalid);
      await expectLater(service.capture(), throwsA(failure('invalid_image')));
    }
  });
}
