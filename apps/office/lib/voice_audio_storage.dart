import 'voice_audio_storage_stub.dart'
    if (dart.library.io) 'voice_audio_storage_io.dart'
    if (dart.library.js_interop) 'voice_audio_storage_web.dart'
    as platform;
import 'voice_audio_storage_types.dart';
export 'voice_audio_storage_types.dart';

OfficeVoiceStorage createOfficeVoiceStorage() => platform.createVoiceStorage();
