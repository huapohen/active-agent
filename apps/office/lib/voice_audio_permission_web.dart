import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Do not query an unsupported Permissions API before a user-triggered request.
/// All temporary permission-probe tracks are stopped, including on failures.
Future<bool?> microphonePermission({required bool request}) async {
  if (!request) return false;
  if (!web.window.isSecureContext) return false;
  web.MediaStream? stream;
  try {
    stream = await web.window.navigator.mediaDevices
        .getUserMedia(
          web.MediaStreamConstraints(audio: true.toJS, video: false.toJS),
        )
        .toDart;
    return true;
  } catch (_) {
    return false;
  } finally {
    for (final track
        in stream?.getTracks().toDart ?? <web.MediaStreamTrack>[]) {
      track.stop();
    }
  }
}
