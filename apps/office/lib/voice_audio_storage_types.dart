import 'dart:typed_data';

class OfficeVoicePlaybackSource {
  const OfficeVoicePlaybackSource(this.location, {this.isBlob = false});
  final String location;
  final bool isBlob;
}

/// Owns only this voice session's files/object URLs. Never accepts a remote
/// authenticated URL as a player source or removes an arbitrary local path.
abstract interface class OfficeVoiceStorage {
  Future<String> createRecordingPath();
  Future<Uint8List> readRecording(String location, {required int maxBytes});
  Future<void> releaseRecording(String location);
  Future<OfficeVoicePlaybackSource> createPlayback(Uint8List bytes);
  Future<void> releasePlayback(OfficeVoicePlaybackSource source);
  Future<void> close();
}
