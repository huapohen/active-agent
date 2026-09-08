import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:active_office/voice_audio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List voiceWaveBytes({
  int sampleRate = 16000,
  int frames = 16000,
  int channels = 1,
  int bits = 16,
  bool extendedFmt = false,
  bool oddJunk = false,
}) {
  final chunks = <int>[];
  void add(String name, Uint8List bytes) {
    chunks.addAll(name.codeUnits);
    final length = ByteData(4)..setUint32(0, bytes.length, Endian.little);
    chunks.addAll(length.buffer.asUint8List());
    chunks.addAll(bytes);
    if (bytes.length.isOdd) chunks.add(0);
  }

  final fmt = ByteData(extendedFmt ? 18 : 16)
    ..setUint16(0, 1, Endian.little)
    ..setUint16(2, channels, Endian.little)
    ..setUint32(4, sampleRate, Endian.little)
    ..setUint32(8, sampleRate * channels * bits ~/ 8, Endian.little)
    ..setUint16(12, channels * bits ~/ 8, Endian.little)
    ..setUint16(14, bits, Endian.little);
  add('fmt ', fmt.buffer.asUint8List());
  if (oddJunk) add('JUNK', Uint8List.fromList([7, 8, 9]));
  final pcm = ByteData(frames * channels * bits ~/ 8);
  for (var i = 0; i + 2 <= pcm.lengthInBytes; i += 2) {
    pcm.setInt16(i, i % 4 == 0 ? 16384 : -8192, Endian.little);
  }
  add('data', pcm.buffer.asUint8List());
  final result = Uint8List(12 + chunks.length);
  result.setRange(0, 4, 'RIFF'.codeUnits);
  ByteData.sublistView(result).setUint32(4, result.length - 8, Endian.little);
  result.setRange(8, 12, 'WAVE'.codeUnits);
  result.setRange(12, result.length, chunks);
  return result;
}

class FakeVoiceRecorderDriver implements OfficeVoiceRecorderDriver {
  bool permission = true, supported = true;
  Completer<bool>? permissionGate;
  Completer<void>? startGate, stopGate;
  String? path;
  int permissionRequests = 0,
      startCalls = 0,
      stopCalls = 0,
      cancelCalls = 0,
      disposeCalls = 0;
  Object? permissionError,
      encoderError,
      startError,
      stopError,
      cancelError,
      disposeError;
  final amplitudeController = StreamController<double>.broadcast(sync: true);
  final stateController =
      StreamController<OfficeVoiceDriverRecordState>.broadcast(sync: true);
  @override
  Future<bool> hasPermission({required bool request}) async {
    if (request) permissionRequests++;
    if (permissionError != null) throw permissionError!;
    return permissionGate?.future ?? permission;
  }

  @override
  Future<bool> supportsWav() async {
    if (encoderError != null) throw encoderError!;
    return supported;
  }

  @override
  Future<void> start(String value) async {
    path = value;
    startCalls++;
    await startGate?.future;
    if (startError != null) throw startError!;
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    if (stopGate != null) await stopGate!.future;
    if (stopError != null) throw stopError!;
    return path;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (cancelError != null) throw cancelError!;
  }

  @override
  Stream<double> get amplitudes => amplitudeController.stream;
  @override
  Stream<OfficeVoiceDriverRecordState> get states => stateController.stream;
  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (disposeError != null) throw disposeError!;
    await amplitudeController.close();
    await stateController.close();
  }
}

class FakeVoicePlaybackDriver implements OfficeVoicePlaybackDriver {
  int playCalls = 0,
      pauseCalls = 0,
      resumeCalls = 0,
      stopCalls = 0,
      disposeCalls = 0;
  final sources = <OfficeVoicePlaybackSource>[];
  final seeks = <Duration>[];
  Completer<void>? playGate, pauseGate;
  Object? playError,
      pauseError,
      resumeError,
      seekError,
      stopError,
      disposeError;
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final durationController = StreamController<Duration>.broadcast(sync: true);
  final stateController =
      StreamController<OfficeVoiceDriverPlaybackState>.broadcast(sync: true);
  @override
  Future<void> play(OfficeVoicePlaybackSource source) async {
    playCalls++;
    sources.add(source);
    await playGate?.future;
    if (playError != null) throw playError!;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    await pauseGate?.future;
    if (pauseError != null) throw pauseError!;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    if (resumeError != null) throw resumeError!;
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    if (seekError != null) throw seekError!;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (stopError != null) throw stopError!;
  }

  @override
  Stream<Duration> get positions => positionController.stream;
  @override
  Stream<Duration> get durations => durationController.stream;
  @override
  Stream<OfficeVoiceDriverPlaybackState> get states => stateController.stream;
  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (disposeError != null) throw disposeError!;
    await positionController.close();
    await durationController.close();
    await stateController.close();
  }
}

class MemoryVoiceStorage implements OfficeVoiceStorage {
  MemoryVoiceStorage({Uint8List? bytes})
    : recordingBytes = bytes ?? voiceWaveBytes();
  Uint8List recordingBytes;
  int counter = 0, closeCalls = 0;
  Object? createError;
  final owned = <String>{}, released = <String>[];
  final playbackBytes = <Uint8List>[];
  @override
  Future<String> createRecordingPath() async {
    if (createError != null) throw createError!;
    final path = '/owned/voice-${++counter}.wav';
    owned.add(path);
    return path;
  }

  @override
  Future<Uint8List> readRecording(
    String location, {
    required int maxBytes,
  }) async {
    if (!owned.contains(location) || recordingBytes.length > maxBytes) {
      throw StateError('unowned or too large');
    }
    return recordingBytes;
  }

  @override
  Future<void> releaseRecording(String location) async {
    if (owned.remove(location)) released.add(location);
  }

  @override
  Future<OfficeVoicePlaybackSource> createPlayback(Uint8List bytes) async {
    final path = await createRecordingPath();
    playbackBytes.add(bytes);
    return OfficeVoicePlaybackSource(path);
  }

  @override
  Future<void> releasePlayback(OfficeVoicePlaybackSource source) =>
      releaseRecording(source.location);
  @override
  Future<void> close() async {
    closeCalls++;
    released.addAll(owned);
    owned.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'start diagnostics identify failures without exposing native details',
    () async {
      const secret = '/private/sensitive/person.wav';
      final cases = <(OfficeVoiceStartStage, Object, String)>[
        (
          OfficeVoiceStartStage.permission,
          MissingPluginException(secret),
          'plugin',
        ),
        (
          OfficeVoiceStartStage.encoder,
          PlatformException(code: secret, message: secret, details: secret),
          'platform',
        ),
        (
          OfficeVoiceStartStage.temporaryStorage,
          const FileSystemException(secret, secret),
          'filesystem',
        ),
        (
          OfficeVoiceStartStage.nativeStart,
          PlatformException(code: 'record', message: secret, details: secret),
          'platform',
        ),
      ];
      for (final (stage, failure, category) in cases) {
        final driver = FakeVoiceRecorderDriver();
        final storage = MemoryVoiceStorage();
        switch (stage) {
          case OfficeVoiceStartStage.permission:
            driver.permissionError = failure;
          case OfficeVoiceStartStage.encoder:
            driver.encoderError = failure;
          case OfficeVoiceStartStage.temporaryStorage:
            storage.createError = failure;
          case OfficeVoiceStartStage.nativeStart:
            driver.startError = failure;
          default:
            fail('Unexpected test stage');
        }
        final recorder = OfficeVoiceRecorder(
          isCurrent: () => true,
          driver: driver,
          storage: storage,
          focus: OfficeVoiceAudioFocus(),
        );
        expect(await recorder.startFromUserGesture(), isFalse);
        expect(recorder.diagnostic?.stage, stage);
        expect(recorder.diagnostic?.category, category);
        expect(recorder.error, contains('VR-${stage.code}-$category'));
        expect(recorder.error, isNot(contains(secret)));
        expect(recorder.diagnostic?.logLine, isNot(contains(secret)));
        await recorder.close();
        recorder.dispose();
      }
    },
  );
  test(
    'failed start cleanup preserves original diagnostic and device focus',
    () async {
      final driver = FakeVoiceRecorderDriver()
        ..startError = PlatformException(
          code: 'record',
          message: 'private native message',
        )
        ..cancelError = StateError('private cancel')
        ..disposeError = StateError('private dispose');
      final focus = OfficeVoiceAudioFocus();
      final recorder = OfficeVoiceRecorder(
        isCurrent: () => true,
        driver: driver,
        storage: MemoryVoiceStorage(),
        focus: focus,
      );
      expect(await recorder.startFromUserGesture(), isFalse);
      expect(recorder.diagnostic?.code, 'VR-start-platform');
      expect(recorder.cleanupDiagnostic?.code, 'VR-cleanup-state');
      expect(recorder.error, isNot(contains('private')));
      expect(focus.recordingActive, isTrue);
      expect(await recorder.startFromUserGesture(), isFalse);
      expect(driver.startCalls, 1);
      driver.cancelError = driver.disposeError = null;
      await recorder.close();
      recorder.dispose();
      expect(focus.recordingActive, isFalse);
    },
  );
  test('actual sample rate, PCM duration, fmt18 and odd ancillary chunks are preserved', () {
    final clip = OfficeVoiceClip.fromWav(
      voiceWaveBytes(
        sampleRate: 44100,
        frames: 22050,
        extendedFmt: true,
        oddJunk: true,
      ),
    );
    expect(clip.sampleRate, 44100);
    expect(clip.durationMs, 500);
    expect(clip.bytes.length, 44 + 44100);
    expect(clip.waveform.every((value) => value == .5), isTrue);
    expect(
      ByteData.sublistView(clip.bytes).getUint32(24, Endian.little),
      44100,
    );
  });
  test('duration cap trims real trailing frames without resampling or inventing amplitude', () {
    final clip = OfficeVoiceClip.fromWav(
      voiceWaveBytes(sampleRate: 48000, frames: 96000),
      maxDuration: const Duration(seconds: 1),
    );
    expect(clip.truncated, isTrue);
    expect(clip.durationMs, 1000);
    expect(clip.sampleRate, 48000);
    expect(clip.bytes.length, 96044);
  });
  test(
    'reject malformed, stereo, non16 PCM and rates outside negotiated range',
    () {
      for (final bytes in [
        Uint8List(44),
        voiceWaveBytes(channels: 2),
        voiceWaveBytes(bits: 8),
        voiceWaveBytes(sampleRate: 96000),
        voiceWaveBytes(frames: 0),
        voiceWaveBytes()..[4] = 0,
      ]) {
        expect(
          () => OfficeVoiceClip.fromWav(bytes),
          throwsA(isA<OfficeVoiceException>()),
        );
      }
    },
  );
  test('constructing recorder never requests permission; explicit denied request does not start a device', () async {
    final driver = FakeVoiceRecorderDriver()..permission = false;
    final storage = MemoryVoiceStorage();
    final recorder = OfficeVoiceRecorder(
      isCurrent: () => true,
      driver: driver,
      storage: storage,
      focus: OfficeVoiceAudioFocus(),
    );
    expect(driver.permissionRequests, 0);
    expect(await recorder.startFromUserGesture(), isFalse);
    expect(driver.permissionRequests, 1);
    expect(driver.startCalls, 0);
    expect(recorder.phase, OfficeVoiceRecorderPhase.error);
    await recorder.close();
    recorder.dispose();
    expect(storage.owned, isEmpty);
  });
  test('real amplitudes and header-derived stop result survive clean temporary deletion', () async {
    final driver = FakeVoiceRecorderDriver(),
        storage = MemoryVoiceStorage(
          bytes: voiceWaveBytes(sampleRate: 48000, frames: 24000),
        );
    final recorder = OfficeVoiceRecorder(
      isCurrent: () => true,
      driver: driver,
      storage: storage,
      focus: OfficeVoiceAudioFocus(),
    );
    expect(await recorder.startFromUserGesture(), isTrue);
    driver.amplitudeController.add(-24);
    driver.amplitudeController.add(double.nan);
    expect(recorder.amplitudeDbfs, -24);
    expect(recorder.amplitudes, [-24]);
    final clip = await recorder.stop();
    expect(clip!.sampleRate, 48000);
    expect(clip.durationMs, 500);
    expect(recorder.elapsed, const Duration(milliseconds: 500));
    expect(recorder.phase, OfficeVoiceRecorderPhase.ready);
    expect(storage.owned, isEmpty);
    await recorder.close();
    recorder.dispose();
  });
  test('cancel while permission pending prevents late capture and blocks unsafe immediate retry', () async {
    final driver = FakeVoiceRecorderDriver()
      ..permissionGate = Completer<bool>();
    final storage = MemoryVoiceStorage(), focus = OfficeVoiceAudioFocus();
    final recorder = OfficeVoiceRecorder(
      isCurrent: () => true,
      driver: driver,
      storage: storage,
      focus: focus,
    );
    final start = recorder.startFromUserGesture();
    await Future<void>.delayed(Duration.zero);
    final cancel = recorder.cancel();
    expect(await recorder.startFromUserGesture(), isFalse);
    driver.permissionGate!.complete(true);
    expect(await start, isFalse);
    await cancel;
    expect(driver.startCalls, 0);
    expect(focus.recordingActive, isFalse);
    expect(recorder.clip, isNull);
    await recorder.close();
    recorder.dispose();
  });
  test('meeting waits for delayed native start cancellation and stale meeting lease cannot unlock a later meeting', () async {
    final driver = FakeVoiceRecorderDriver()..startGate = Completer<void>();
    final storage = MemoryVoiceStorage(), focus = OfficeVoiceAudioFocus();
    final recorder = OfficeVoiceRecorder(
      isCurrent: () => true,
      driver: driver,
      storage: storage,
      focus: focus,
    );
    final start = recorder.startFromUserGesture();
    await Future<void>.delayed(Duration.zero);
    expect(driver.startCalls, 1);
    var meetingReturned = false;
    final pending = focus.beginMeeting().then((value) {
      meetingReturned = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(meetingReturned, isFalse);
    driver.startGate!.complete();
    expect(await start, isFalse);
    final old = await pending;
    expect(driver.cancelCalls, 1);
    expect(storage.owned, isEmpty);
    await expectLater(
      focus.beginMeeting(),
      throwsA(isA<OfficeVoiceException>()),
    );
    focus.endMeeting(old);
    final newer = await focus.beginMeeting();
    focus.endMeeting(old);
    expect(focus.meetingActive, isTrue);
    expect(await recorder.startFromUserGesture(), isFalse);
    focus.endMeeting(newer);
    expect(focus.meetingActive, isFalse);
    await recorder.close();
    recorder.dispose();
  });
  test(
    'identity changes during slow stop never expose an old voice clip',
    () async {
      var current = true;
      final driver = FakeVoiceRecorderDriver()..stopGate = Completer<void>();
      final storage = MemoryVoiceStorage();
      final recorder = OfficeVoiceRecorder(
        isCurrent: () => current,
        driver: driver,
        storage: storage,
        focus: OfficeVoiceAudioFocus(),
      );
      await recorder.startFromUserGesture();
      final stop = recorder.stop();
      await Future<void>.delayed(Duration.zero);
      current = false;
      final cancel = recorder.cancel();
      driver.stopGate!.complete();
      expect(await stop, isNull);
      await cancel;
      expect(recorder.clip, isNull);
      expect(storage.owned, isEmpty);
      await recorder.close();
      recorder.dispose();
    },
  );
  test(
    'system interruption and background cancel instead of auto sending',
    () async {
      final driver = FakeVoiceRecorderDriver(), storage = MemoryVoiceStorage();
      final recorder = OfficeVoiceRecorder(
        isCurrent: () => true,
        driver: driver,
        storage: storage,
        focus: OfficeVoiceAudioFocus(),
      );
      await recorder.startFromUserGesture();
      driver.stateController.add(OfficeVoiceDriverRecordState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(recorder.phase, OfficeVoiceRecorderPhase.error);
      expect(recorder.clip, isNull);
      expect(storage.owned, isEmpty);
      await recorder.startFromUserGesture();
      recorder.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(recorder.phase, OfficeVoiceRecorderPhase.idle);
      expect(driver.cancelCalls, 2);
      await recorder.close();
      recorder.dispose();
    },
  );
  test(
    'cancel falls back to disposing a device that rejects cancellation',
    () async {
      final driver = FakeVoiceRecorderDriver()
        ..cancelError = StateError('cancel failed');
      final storage = MemoryVoiceStorage(), focus = OfficeVoiceAudioFocus();
      final recorder = OfficeVoiceRecorder(
        isCurrent: () => true,
        driver: driver,
        storage: storage,
        focus: focus,
      );
      await recorder.startFromUserGesture();
      await recorder.cancel();
      expect(driver.disposeCalls, 1);
      expect(focus.recordingActive, isFalse);
      expect(storage.owned, isEmpty);
      await recorder.close();
      recorder.dispose();
    },
  );
  test('only one player runs; bytes remain controlled and finish deletes the source', () async {
    final focus = OfficeVoiceAudioFocus();
    final firstDriver = FakeVoicePlaybackDriver(),
        secondDriver = FakeVoicePlaybackDriver();
    final firstStorage = MemoryVoiceStorage(),
        secondStorage = MemoryVoiceStorage();
    final first = OfficeVoicePlayback(
      isCurrent: () => true,
      driver: firstDriver,
      storage: firstStorage,
      focus: focus,
    );
    final second = OfficeVoicePlayback(
      isCurrent: () => true,
      driver: secondDriver,
      storage: secondStorage,
      focus: focus,
    );
    await first.playBytes(id: 'one', bytes: voiceWaveBytes());
    await second.playBytes(id: 'two', bytes: voiceWaveBytes());
    expect(first.phase, OfficeVoicePlaybackPhase.idle);
    expect(firstStorage.owned, isEmpty);
    expect(second.phase, OfficeVoicePlaybackPhase.playing);
    expect(secondDriver.sources.single.location.startsWith('/owned/'), isTrue);
    secondDriver.positionController.add(const Duration(milliseconds: 450));
    expect(second.position.inMilliseconds, 450);
    await second.pause();
    expect(second.phase, OfficeVoicePlaybackPhase.paused);
    await second.seek(const Duration(seconds: 3));
    expect(secondDriver.seeks.last, const Duration(seconds: 1));
    await second.resume();
    secondDriver.stateController.add(OfficeVoiceDriverPlaybackState.completed);
    await Future<void>.delayed(Duration.zero);
    expect(second.phase, OfficeVoicePlaybackPhase.completed);
    expect(secondStorage.owned, isEmpty);
    await first.close();
    await second.close();
    first.dispose();
    second.dispose();
  });
  test('delayed playback setup and identity exit never starts a new scope or retains bytes', () async {
    final driver = FakeVoicePlaybackDriver()..playGate = Completer<void>();
    final storage = MemoryVoiceStorage();
    var current = true;
    final player = OfficeVoicePlayback(
      isCurrent: () => current,
      driver: driver,
      storage: storage,
      focus: OfficeVoiceAudioFocus(),
    );
    final play = player.playBytes(id: 'old', bytes: voiceWaveBytes());
    await Future<void>.delayed(Duration.zero);
    current = false;
    final stop = player.stop();
    driver.playGate!.complete();
    await play;
    await stop;
    expect(player.currentId, isNull);
    expect(player.phase, OfficeVoicePlaybackPhase.idle);
    expect(storage.owned, isEmpty);
    await player.close();
    player.dispose();
  });
  for (final failure in ['pause', 'resume', 'seek']) {
    test(
      '$failure failures reach error state and release temporary playback without uncaught future',
      () async {
        final driver = FakeVoicePlaybackDriver(),
            storage = MemoryVoiceStorage();
        final player = OfficeVoicePlayback(
          isCurrent: () => true,
          driver: driver,
          storage: storage,
          focus: OfficeVoiceAudioFocus(),
        );
        await player.playBytes(id: 'voice', bytes: voiceWaveBytes());
        if (failure == 'pause') {
          driver.pauseError = StateError('pause');
          await player.pause();
        }
        if (failure == 'resume') {
          await player.pause();
          driver.resumeError = StateError('resume');
          await player.resume();
        }
        if (failure == 'seek') {
          driver.seekError = StateError('seek');
          await player.seek(const Duration(milliseconds: 10));
        }
        expect(player.phase, OfficeVoicePlaybackPhase.error);
        expect(storage.owned, isEmpty);
        expect(player.error, isNotEmpty);
        await player.close();
        player.dispose();
      },
    );
  }
  test('meeting blocks recording and playback before either native device operation', () async {
    final focus = OfficeVoiceAudioFocus();
    final lease = await focus.beginMeeting();
    final driver = FakeVoicePlaybackDriver(),
        recorderDriver = FakeVoiceRecorderDriver();
    final player = OfficeVoicePlayback(
      isCurrent: () => true,
      driver: driver,
      storage: MemoryVoiceStorage(),
      focus: focus,
    );
    final recorder = OfficeVoiceRecorder(
      isCurrent: () => true,
      driver: recorderDriver,
      storage: MemoryVoiceStorage(),
      focus: focus,
    );
    await player.playBytes(id: 'voice', bytes: voiceWaveBytes());
    expect(driver.playCalls, 0);
    expect(player.phase, OfficeVoicePlaybackPhase.error);
    expect(await recorder.startFromUserGesture(), isFalse);
    expect(recorderDriver.permissionRequests, 0);
    focus.endMeeting(lease);
    await player.close();
    await recorder.close();
    player.dispose();
    recorder.dispose();
  });
  test('failed recorder shutdown keeps focus until an actual retry succeeds and does not leave a phantom meeting', () async {
    final driver = FakeVoiceRecorderDriver()
      ..cancelError = StateError('cancel')
      ..disposeError = StateError('dispose');
    final storage = MemoryVoiceStorage(), focus = OfficeVoiceAudioFocus();
    final recorder = OfficeVoiceRecorder(
      isCurrent: () => true,
      driver: driver,
      storage: storage,
      focus: focus,
    );
    await recorder.startFromUserGesture();
    await expectLater(focus.beginMeeting(), throwsStateError);
    expect(focus.meetingActive, isFalse);
    expect(focus.recordingActive, isTrue);
    expect(storage.owned, isNotEmpty);
    driver.cancelError = null;
    driver.disposeError = null;
    final lease = await focus.beginMeeting();
    expect(focus.recordingActive, isFalse);
    expect(storage.owned, isEmpty);
    focus.endMeeting(lease);
    await recorder.close();
    recorder.dispose();
  });
  test('failed previous player shutdown blocks replacement and the next meeting retries the same device', () async {
    final focus = OfficeVoiceAudioFocus();
    final driver = FakeVoicePlaybackDriver(),
        secondDriver = FakeVoicePlaybackDriver();
    final storage = MemoryVoiceStorage();
    final player = OfficeVoicePlayback(
      isCurrent: () => true,
      driver: driver,
      storage: storage,
      focus: focus,
    );
    final second = OfficeVoicePlayback(
      isCurrent: () => true,
      driver: secondDriver,
      storage: MemoryVoiceStorage(),
      focus: focus,
    );
    await player.playBytes(id: 'old', bytes: voiceWaveBytes());
    driver.stopError = StateError('stop');
    driver.disposeError = StateError('dispose');
    await second.playBytes(id: 'new', bytes: voiceWaveBytes());
    expect(second.phase, OfficeVoicePlaybackPhase.error);
    expect(secondDriver.playCalls, 0);
    expect(storage.owned, isNotEmpty);
    await expectLater(focus.beginMeeting(), throwsStateError);
    expect(focus.meetingActive, isFalse);
    driver.stopError = null;
    driver.disposeError = null;
    final lease = await focus.beginMeeting();
    expect(storage.owned, isEmpty);
    focus.endMeeting(lease);
    await player.close();
    await second.close();
    player.dispose();
    second.dispose();
  });
  test('queued controls from an earlier message never seek the replacement message', () async {
    final driver = FakeVoicePlaybackDriver()..pauseGate = Completer<void>();
    final player = OfficeVoicePlayback(
      isCurrent: () => true,
      driver: driver,
      storage: MemoryVoiceStorage(),
      focus: OfficeVoiceAudioFocus(),
    );
    await player.playBytes(id: 'one', bytes: voiceWaveBytes());
    final pause = player.pause();
    await Future<void>.delayed(Duration.zero);
    final seek = player.seek(const Duration(milliseconds: 300));
    final replacement = player.playBytes(id: 'two', bytes: voiceWaveBytes());
    driver.pauseGate!.complete();
    await pause;
    await seek;
    await replacement;
    expect(driver.seeks, isEmpty);
    expect(driver.playCalls, 2);
    expect(player.currentId, 'two');
    expect(player.phase, OfficeVoicePlaybackPhase.playing);
    await player.close();
    player.dispose();
  });
}
