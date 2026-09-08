import 'dart:async';

import 'package:audioplayers/audioplayers.dart' as audio;
import 'package:record/record.dart' as record;

import 'voice_audio_permission.dart';
import 'voice_audio_storage_types.dart';

enum OfficeVoiceDriverRecordState { recording, paused, stopped }

enum OfficeVoiceDriverPlaybackState { playing, paused, stopped, completed }

abstract interface class OfficeVoiceRecorderDriver {
  Future<bool> hasPermission({required bool request});
  Future<bool> supportsWav();
  Future<void> start(String path);
  Future<String?> stop();
  Future<void> cancel();
  Stream<double> get amplitudes;
  Stream<OfficeVoiceDriverRecordState> get states;
  Future<void> dispose();
}

class OfficePluginVoiceRecorder implements OfficeVoiceRecorderDriver {
  record.AudioRecorder? _instance;
  record.AudioRecorder get _recorder => _instance ??= record.AudioRecorder();
  @override
  Future<bool> hasPermission({required bool request}) async =>
      await officeVoiceWebPermission(request: request) ??
      await _recorder.hasPermission(request: request);
  @override
  Future<bool> supportsWav() =>
      _recorder.isEncoderSupported(record.AudioEncoder.wav);
  @override
  Future<void> start(String path) => _recorder.start(
    const record.RecordConfig(
      encoder: record.AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
      audioInterruption: record.AudioInterruptionMode.pause,
    ),
    path: path,
  );
  @override
  Future<String?> stop() => _recorder.stop();
  @override
  Future<void> cancel() async {
    if (_instance != null) await _instance!.cancel();
  }

  @override
  Stream<double> get amplitudes => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .map((event) => event.current);
  @override
  Stream<OfficeVoiceDriverRecordState> get states =>
      _recorder.onStateChanged().map(
        (state) => switch (state) {
          record.RecordState.record => OfficeVoiceDriverRecordState.recording,
          record.RecordState.pause => OfficeVoiceDriverRecordState.paused,
          record.RecordState.stop => OfficeVoiceDriverRecordState.stopped,
        },
      );
  @override
  Future<void> dispose() async {
    await _instance?.dispose();
    _instance = null;
  }
}

abstract interface class OfficeVoicePlaybackDriver {
  Future<void> play(OfficeVoicePlaybackSource source);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration position);
  Future<void> stop();
  Stream<Duration> get positions;
  Stream<Duration> get durations;
  Stream<OfficeVoiceDriverPlaybackState> get states;
  Future<void> dispose();
}

class OfficePluginVoicePlayback implements OfficeVoicePlaybackDriver {
  audio.AudioPlayer? _instance;
  audio.AudioPlayer get _player => _instance ??= audio.AudioPlayer();
  @override
  Future<void> play(OfficeVoicePlaybackSource source) async {
    await _player.setReleaseMode(audio.ReleaseMode.stop);
    await _player.play(
      source.isBlob
          ? audio.UrlSource(source.location, mimeType: 'audio/wav')
          : audio.DeviceFileSource(source.location, mimeType: 'audio/wav'),
    );
  }

  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> resume() => _player.resume();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> stop() async {
    if (_instance != null) await _instance!.stop();
  }

  @override
  Stream<Duration> get positions => _player.onPositionChanged;
  @override
  Stream<Duration> get durations => _player.onDurationChanged;
  @override
  Stream<OfficeVoiceDriverPlaybackState> get states => Stream.multi((
    controller,
  ) {
    final states = _player.onPlayerStateChanged.listen(
      (state) => controller.add(switch (state) {
        audio.PlayerState.playing => OfficeVoiceDriverPlaybackState.playing,
        audio.PlayerState.paused => OfficeVoiceDriverPlaybackState.paused,
        audio.PlayerState.completed => OfficeVoiceDriverPlaybackState.completed,
        _ => OfficeVoiceDriverPlaybackState.stopped,
      }),
      onError: controller.addError,
    );
    final errors = _player.eventStream.listen(
      (_) {},
      onError: controller.addError,
    );
    controller.onCancel = () async {
      await states.cancel();
      await errors.cancel();
    };
  }, isBroadcast: true);
  @override
  Future<void> dispose() async {
    await _instance?.dispose();
    _instance = null;
  }
}
