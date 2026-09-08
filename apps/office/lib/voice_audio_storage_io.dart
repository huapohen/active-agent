import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'voice_audio_storage_types.dart';

OfficeVoiceStorage createVoiceStorage({
  Future<Directory> Function()? temporaryDirectory,
}) => _FileVoiceStorage(temporaryDirectory ?? getTemporaryDirectory);

class _FileVoiceStorage implements OfficeVoiceStorage {
  _FileVoiceStorage(this._temporaryDirectory);
  final Future<Directory> Function() _temporaryDirectory;
  Directory? _directory;
  Future<Directory>? _creating;
  final Set<String> _owned = {};
  bool _closed = false;
  int _counter = 0;
  Future<Directory> _root() {
    if (_closed) throw StateError('语音临时空间已关闭');
    return _creating ??= () async {
      try {
        final parent = await _temporaryDirectory();
        // Foundation may return Caches/bundleID before that directory exists.
        // Own only the random child: never delete the shared cache parent.
        await parent.create(recursive: true);
        final directory = await parent.createTemp('renji-voice-');
        if (_closed) {
          await directory.delete(recursive: true);
          throw StateError('语音临时空间已关闭');
        }
        return _directory = directory;
      } catch (_) {
        // A repaired filesystem or a later permission grant can be retried.
        _creating = null;
        rethrow;
      }
    }();
  }

  @override
  Future<String> createRecordingPath() async {
    final root = await _root();
    final path = '${root.path}${Platform.pathSeparator}voice-${++_counter}.wav';
    _owned.add(path);
    return path;
  }

  @override
  Future<Uint8List> readRecording(
    String location, {
    required int maxBytes,
  }) async {
    if (!_owned.contains(location)) throw StateError('录音返回了非本次会话的文件');
    final file = File(location);
    if (await file.length() > maxBytes) throw StateError('录音文件超过大小限制');
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) throw StateError('录音文件超过大小限制');
    return bytes;
  }

  @override
  Future<void> releaseRecording(String location) async {
    if (!_owned.remove(location)) return;
    final file = File(location);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<OfficeVoicePlaybackSource> createPlayback(Uint8List bytes) async {
    final path = await createRecordingPath();
    try {
      await File(path).writeAsBytes(bytes, flush: true);
    } catch (_) {
      await releaseRecording(path);
      rethrow;
    }
    return OfficeVoicePlaybackSource(path);
  }

  @override
  Future<void> releasePlayback(OfficeVoicePlaybackSource source) =>
      releaseRecording(source.location);
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final pending = _creating;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final directory = _directory;
    _owned.clear();
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
