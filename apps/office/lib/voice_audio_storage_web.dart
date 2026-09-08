import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'voice_audio_storage_types.dart';

OfficeVoiceStorage createVoiceStorage() => _BlobVoiceStorage();

class _BlobVoiceStorage implements OfficeVoiceStorage {
  final Set<String> _owned = {};
  bool _closed = false;
  bool _localBlob(String location) =>
      location.startsWith('blob:${web.window.location.origin}/');
  @override
  Future<String> createRecordingPath() async {
    if (_closed) throw StateError('语音临时空间已关闭');
    return 'voice.wav'; // record_web ignores paths and returns its own Blob URL.
  }

  @override
  Future<Uint8List> readRecording(
    String location, {
    required int maxBytes,
  }) async {
    if (_closed || !_localBlob(location)) throw StateError('录音没有返回当前页面的 Blob');
    _owned.add(location);
    final response = await web.window.fetch(location.toJS).toDart;
    if (!response.ok) throw StateError('无法读取本次录音');
    final blob = await response.blob().toDart;
    if (blob.size > maxBytes) throw StateError('录音文件超过大小限制');
    final bytes = (await blob.arrayBuffer().toDart).toDart.asUint8List();
    if (bytes.length > maxBytes) throw StateError('录音文件超过大小限制');
    return bytes;
  }

  @override
  Future<void> releaseRecording(String location) async {
    if (_localBlob(location)) {
      _owned.remove(location);
      web.URL.revokeObjectURL(location);
    }
  }

  @override
  Future<OfficeVoicePlaybackSource> createPlayback(Uint8List bytes) async {
    if (_closed) throw StateError('语音临时空间已关闭');
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'audio/wav'),
    );
    final location = web.URL.createObjectURL(blob);
    _owned.add(location);
    return OfficeVoicePlaybackSource(location, isBlob: true);
  }

  @override
  Future<void> releasePlayback(OfficeVoicePlaybackSource source) async {
    if (_owned.remove(source.location)) {
      web.URL.revokeObjectURL(source.location);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final url in _owned) {
      web.URL.revokeObjectURL(url);
    }
    _owned.clear();
  }
}
