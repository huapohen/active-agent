import 'voice_audio_permission_stub.dart'
    if (dart.library.js_interop) 'voice_audio_permission_web.dart'
    as platform;

Future<bool?> officeVoiceWebPermission({required bool request}) =>
    platform.microphonePermission(request: request);
