import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter/widgets.dart';

import 'voice_audio_clip.dart';
import 'voice_audio_drivers.dart';
import 'voice_audio_storage.dart';
export 'voice_audio_clip.dart';
export 'voice_audio_drivers.dart';
export 'voice_audio_storage.dart';

enum OfficeVoiceRecorderPhase {
  idle,
  requestingPermission,
  recording,
  stopping,
  ready,
  error,
}

enum OfficeVoiceStartStage {
  audioFocus('focus'),
  permission('permission'),
  encoder('encoder'),
  temporaryStorage('storage'),
  nativeStart('start'),
  amplitudeStream('amplitude'),
  stateStream('state'),
  cleanup('cleanup');

  const OfficeVoiceStartStage(this.code);
  final String code;
}

/// Contains only fixed vocabulary: never native messages, paths or stack traces.
class OfficeVoiceDiagnostic {
  OfficeVoiceDiagnostic(this.stage, Object failure)
    : category = _category(failure),
      platformCode = failure is PlatformException && failure.code == 'record'
          ? 'record'
          : null;

  final OfficeVoiceStartStage stage;
  final String category;
  final String? platformCode;
  String get code => 'VR-${stage.code}-$category';
  String get logLine =>
      '[voice-recorder] $code${platformCode == null ? '' : ' platform=$platformCode'}';

  static String _category(Object failure) {
    if (failure is MissingPluginException) return 'plugin';
    if (failure is PlatformException) return 'platform';
    if (failure is OfficeVoiceException) {
      return switch (failure.code) {
        'permission_denied' => 'denied',
        'unsupported_encoder' => 'unsupported',
        _ => 'voice',
      };
    }
    if (failure is StateError) return 'state';
    if (failure is ArgumentError) return 'argument';
    if (failure is UnsupportedError) return 'unsupported';
    if (failure is TimeoutException) return 'timeout';
    // Keep this shared service web-compatible; only compare known IO type names.
    if (const {
      'FileSystemException',
      'PathNotFoundException',
      'PathAccessException',
      'PathExistsException',
    }.contains(failure.runtimeType.toString())) {
      return 'filesystem';
    }
    return 'unknown';
  }
}

enum OfficeVoicePlaybackPhase {
  idle,
  loading,
  playing,
  paused,
  completed,
  error,
}

class OfficeVoiceMeetingLease {
  OfficeVoiceMeetingLease._();
}

/// A meeting marks its lease before waiting for voice cancellation. A stale
/// meeting cleanup cannot release a later meeting's lease.
class OfficeVoiceAudioFocus {
  static final instance = OfficeVoiceAudioFocus();
  OfficeVoiceMeetingLease? _meeting;
  Object? _recorder, _player;
  Future<void> Function()? _cancelRecording, _stopPlayback;
  bool get meetingActive => _meeting != null;
  bool get recordingActive => _recorder != null;
  Future<OfficeVoiceMeetingLease> beginMeeting() async {
    if (_meeting != null) {
      throw const OfficeVoiceException('audio_busy', '另一会议仍在使用音频，请退出后重试');
    }
    final lease = OfficeVoiceMeetingLease._();
    _meeting = lease;
    try {
      await _cancelRecording?.call();
      await _stopPlayback?.call();
      return lease;
    } catch (_) {
      endMeeting(lease);
      rethrow;
    }
  }

  void endMeeting(OfficeVoiceMeetingLease lease) {
    if (identical(_meeting, lease)) _meeting = null;
  }

  bool reserveRecording(Object owner, Future<void> Function() cancel) {
    if (_meeting != null || _recorder != null && !identical(_recorder, owner)) {
      return false;
    }
    _recorder = owner;
    _cancelRecording = cancel;
    return true;
  }

  bool ownsRecording(Object owner) =>
      identical(_recorder, owner) && _meeting == null;
  void releaseRecording(Object owner) {
    if (identical(_recorder, owner)) {
      _recorder = null;
      _cancelRecording = null;
    }
  }

  Future<void> stopPlayback() async {
    await _stopPlayback?.call();
  }

  Future<bool> reservePlayback(
    Object owner,
    Future<void> Function() stop,
  ) async {
    if (_meeting != null || _recorder != null) return false;
    final previous = _stopPlayback, previousOwner = _player;
    _player = owner;
    _stopPlayback = stop;
    if (!identical(previousOwner, owner)) {
      try {
        await previous?.call();
      } catch (_) {
        // Keep the previous device accountable when both stop and dispose fail.
        // A later retry or meeting must finish stopping it before taking focus.
        if (identical(_player, owner)) {
          _player = previousOwner;
          _stopPlayback = previous;
        }
        rethrow;
      }
    }
    return ownsPlayback(owner);
  }

  bool ownsPlayback(Object owner) =>
      identical(_player, owner) && _meeting == null && _recorder == null;
  void releasePlayback(Object owner) {
    if (identical(_player, owner)) {
      _player = null;
      _stopPlayback = null;
    }
  }
}

mixin _VoiceSerial {
  Future<void> _tail = Future.value();
  int _pending = 0;
  bool get hasPending => _pending > 0;
  Future<T> serial<T>(Future<T> Function() action) {
    _pending++;
    final result = _tail.then((_) => action()).whenComplete(() => _pending--);
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class OfficeVoiceRecorder extends ChangeNotifier
    with WidgetsBindingObserver, _VoiceSerial {
  OfficeVoiceRecorder({
    required this.isCurrent,
    this.microphoneBusy,
    OfficeVoiceRecorderDriver? driver,
    OfficeVoiceStorage? storage,
    OfficeVoiceAudioFocus? focus,
    this.maxDuration = const Duration(seconds: 60),
    this.maxBytes = 12 * 1024 * 1024,
  }) : _driver = driver ?? OfficePluginVoiceRecorder(),
       _storage = storage ?? createOfficeVoiceStorage(),
       _focus = focus ?? OfficeVoiceAudioFocus.instance {
    WidgetsBinding.instance.addObserver(this);
  }
  final bool Function() isCurrent;
  final bool Function()? microphoneBusy;
  final OfficeVoiceRecorderDriver _driver;
  final OfficeVoiceStorage _storage;
  final OfficeVoiceAudioFocus _focus;
  final Duration maxDuration;
  final int maxBytes;
  OfficeVoiceRecorderPhase phase = OfficeVoiceRecorderPhase.idle;
  Duration elapsed = Duration.zero;
  double? amplitudeDbfs;
  final List<double> _amplitudes = [];
  List<double> get amplitudes => List.unmodifiable(_amplitudes);
  OfficeVoiceClip? clip;
  String? error;
  OfficeVoiceDiagnostic? diagnostic, cleanupDiagnostic;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  StreamSubscription<double>? _amplitudeSubscription;
  StreamSubscription<OfficeVoiceDriverRecordState>? _stateSubscription;
  String? _path;
  bool _deviceRecording = false, _closed = false, _disposed = false;
  int _generation = 0;
  Future<void>? _closing;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _background(Future<dynamic> operation) async {
    final generation = _generation;
    try {
      await operation;
    } catch (_) {
      if (!_closed && generation == _generation) {
        phase = OfficeVoiceRecorderPhase.error;
        error = '无法关闭录音设备，请关闭页面后重试';
        _notify();
      }
    }
  }

  bool _current(int generation) =>
      !_closed &&
      generation == _generation &&
      isCurrent() &&
      microphoneBusy?.call() != true &&
      _focus.ownsRecording(this);
  Future<void> _stopMonitoring() async {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    await _stateSubscription?.cancel();
    _stateSubscription = null;
  }

  Future<void> _discardDevice() async {
    await _stopMonitoring();
    if (_deviceRecording) {
      try {
        await _driver.cancel();
      } catch (_) {
        await _driver.dispose();
      }
      _deviceRecording = false;
    }
    final path = _path;
    _path = null;
    try {
      if (path != null) await _storage.releaseRecording(path);
    } finally {
      _focus.releaseRecording(this);
    }
  }

  /// Call only from an explicit human gesture. Construction, capability reads,
  /// Agent protocols and background refresh never request microphone access.
  Future<bool> startFromUserGesture() {
    if (_closed ||
        _deviceRecording ||
        hasPending ||
        phase == OfficeVoiceRecorderPhase.requestingPermission ||
        phase == OfficeVoiceRecorderPhase.recording ||
        phase == OfficeVoiceRecorderPhase.stopping) {
      return Future.value(false);
    }
    final generation = ++_generation;
    error = null;
    diagnostic = cleanupDiagnostic = null;
    clip = null;
    elapsed = Duration.zero;
    amplitudeDbfs = null;
    _amplitudes.clear();
    if (!isCurrent() ||
        microphoneBusy?.call() == true ||
        !_focus.reserveRecording(this, cancel)) {
      phase = OfficeVoiceRecorderPhase.error;
      error = '会议或其他录音正在使用音频，请结束后重试';
      _notify();
      return Future.value(false);
    }
    phase = OfficeVoiceRecorderPhase.requestingPermission;
    _notify();
    return serial(() async {
      var stage = OfficeVoiceStartStage.audioFocus;
      try {
        await _focus.stopPlayback();
        if (!_current(generation)) {
          await _discardDevice();
          return false;
        }
        stage = OfficeVoiceStartStage.permission;
        if (!await _driver.hasPermission(request: true)) {
          throw const OfficeVoiceException(
            'permission_denied',
            '未获得麦克风权限，请在系统设置中允许后重试',
          );
        }
        if (!_current(generation)) {
          await _discardDevice();
          return false;
        }
        stage = OfficeVoiceStartStage.encoder;
        if (!await _driver.supportsWav()) {
          throw const OfficeVoiceException(
            'unsupported_encoder',
            '当前设备不支持 WAV 录音',
          );
        }
        stage = OfficeVoiceStartStage.temporaryStorage;
        _path = await _storage.createRecordingPath();
        if (!_current(generation)) {
          await _discardDevice();
          return false;
        }
        _deviceRecording = true;
        stage = OfficeVoiceStartStage.nativeStart;
        await _driver.start(_path!);
        if (!_current(generation)) {
          await _discardDevice();
          return false;
        }
        _clock
          ..reset()
          ..start();
        phase = OfficeVoiceRecorderPhase.recording;
        stage = OfficeVoiceStartStage.amplitudeStream;
        _amplitudeSubscription = _driver.amplitudes.listen((value) {
          if (!_current(generation) ||
              phase != OfficeVoiceRecorderPhase.recording ||
              !value.isFinite) {
            return;
          }
          amplitudeDbfs = value.clamp(-120, 0);
          _amplitudes.add(amplitudeDbfs!);
          if (_amplitudes.length > 600) _amplitudes.removeAt(0);
          _notify();
        }, onError: (Object _) => _interrupt('无法读取录音设备，请重新录制'));
        stage = OfficeVoiceStartStage.stateStream;
        _stateSubscription = _driver.states.listen((state) {
          if (_current(generation) &&
              phase == OfficeVoiceRecorderPhase.recording &&
              state != OfficeVoiceDriverRecordState.recording) {
            _interrupt('录音被系统中断，请重新录制');
          }
        }, onError: (Object _) => _interrupt('录音设备发生错误，请重试'));
        _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (!_current(generation)) {
            unawaited(_background(cancel()));
            return;
          }
          elapsed = _clock.elapsed;
          if (elapsed >= maxDuration) {
            unawaited(_background(stop()));
          } else {
            _notify();
          }
        });
        _notify();
        return true;
      } catch (failure) {
        final source = OfficeVoiceDiagnostic(stage, failure);
        debugPrint(source.logLine);
        OfficeVoiceDiagnostic? cleanup;
        try {
          await _discardDevice();
        } catch (cleanupFailure) {
          cleanup = OfficeVoiceDiagnostic(
            OfficeVoiceStartStage.cleanup,
            cleanupFailure,
          );
          debugPrint(cleanup.logLine);
        }
        if (!_closed && generation == _generation) {
          phase = OfficeVoiceRecorderPhase.error;
          diagnostic = source;
          cleanupDiagnostic = cleanup;
          final message = source.category == 'denied'
              ? '未获得麦克风权限，请在系统设置中允许后重试'
              : switch (stage) {
                  OfficeVoiceStartStage.audioFocus => '无法停止正在播放的语音，请关闭后重试',
                  OfficeVoiceStartStage.permission => '无法检查麦克风权限，请重新打开应用',
                  OfficeVoiceStartStage.encoder => '当前设备无法使用所需录音格式',
                  OfficeVoiceStartStage.temporaryStorage => '无法准备录音存储空间，请重试',
                  _ => '无法启动录音设备，请重试',
                };
          error = '$message（${source.code}）';
          if (cleanup != null) error = '$error。设备关闭失败，请关闭页面后重试';
          _notify();
        }
        return false;
      }
    });
  }

  void _interrupt(String message) {
    unawaited(
      _background(
        cancel().then((_) {
          if (!_closed) {
            error = message;
            phase = OfficeVoiceRecorderPhase.error;
            _notify();
          }
        }),
      ),
    );
  }

  Future<OfficeVoiceClip?> stop() {
    if (phase != OfficeVoiceRecorderPhase.recording) return Future.value(clip);
    final generation = _generation;
    phase = OfficeVoiceRecorderPhase.stopping;
    _timer?.cancel();
    _clock.stop();
    elapsed = _clock.elapsed;
    _notify();
    return serial(() async {
      String? returned;
      try {
        await _stopMonitoring();
        returned = await _driver.stop();
        _deviceRecording = false;
        if (!_current(generation)) return null;
        if (returned == null) {
          throw const OfficeVoiceException('empty_recording', '没有获取到录音文件，请重试');
        }
        final bytes = await _storage.readRecording(
          returned,
          maxBytes: maxBytes,
        );
        final result = OfficeVoiceClip.fromWav(
          bytes,
          maxBytes: maxBytes,
          maxDuration: maxDuration,
          filename: 'voice-${DateTime.now().microsecondsSinceEpoch}.wav',
        );
        if (!_current(generation)) return null;
        clip = result;
        elapsed = result.duration;
        phase = OfficeVoiceRecorderPhase.ready;
        error = null;
        _notify();
        return result;
      } catch (failure) {
        if (!_closed && generation == _generation) {
          phase = OfficeVoiceRecorderPhase.error;
          error = failure is OfficeVoiceException
              ? failure.message
              : '无法保存录音，请重新录制';
          _notify();
        }
        return null;
      } finally {
        try {
          if (returned != null) await _storage.releaseRecording(returned);
        } finally {
          await _discardDevice();
        }
      }
    });
  }

  Future<void> cancel() {
    ++_generation;
    clip = null;
    elapsed = Duration.zero;
    amplitudeDbfs = null;
    _amplitudes.clear();
    phase = OfficeVoiceRecorderPhase.idle;
    _timer?.cancel();
    _notify();
    return serial(_discardDevice);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_background(cancel()));
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    return _closing = () async {
      try {
        await cancel();
      } finally {
        try {
          await _driver.dispose();
          _deviceRecording = false;
          _focus.releaseRecording(this);
        } finally {
          await _storage.close();
        }
      }
    }();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}

class OfficeVoicePlayback extends ChangeNotifier
    with WidgetsBindingObserver, _VoiceSerial {
  OfficeVoicePlayback({
    required this.isCurrent,
    OfficeVoicePlaybackDriver? driver,
    OfficeVoiceStorage? storage,
    OfficeVoiceAudioFocus? focus,
    this.maxBytes = 12 * 1024 * 1024,
  }) : _driver = driver ?? OfficePluginVoicePlayback(),
       _storage = storage ?? createOfficeVoiceStorage(),
       _focus = focus ?? OfficeVoiceAudioFocus.instance {
    WidgetsBinding.instance.addObserver(this);
  }
  final bool Function() isCurrent;
  final OfficeVoicePlaybackDriver _driver;
  final OfficeVoiceStorage _storage;
  final OfficeVoiceAudioFocus _focus;
  final int maxBytes;
  OfficeVoicePlaybackPhase phase = OfficeVoicePlaybackPhase.idle;
  String? currentId, error;
  Duration position = Duration.zero, duration = Duration.zero;
  OfficeVoicePlaybackSource? _source;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _guard;
  int _generation = 0;
  bool _closed = false, _disposed = false;
  Future<void>? _closing;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _background(Future<void> operation) async {
    final generation = _generation;
    try {
      await operation;
    } catch (_) {
      if (!_closed && generation == _generation) {
        phase = OfficeVoicePlaybackPhase.error;
        error = '无法停止语音设备，请关闭页面后重试';
        _notify();
      }
    }
  }

  bool _current(int generation) =>
      !_closed &&
      generation == _generation &&
      isCurrent() &&
      _focus.ownsPlayback(this);
  Future<void> _cleanup() async {
    _guard?.cancel();
    _guard = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    try {
      await _driver.stop();
    } catch (_) {
      await _driver.dispose();
    }
    final source = _source;
    _source = null;
    try {
      if (source != null) await _storage.releasePlayback(source);
    } finally {
      _focus.releasePlayback(this);
    }
  }

  Future<void> playBytes({required String id, required Uint8List bytes}) {
    final generation = ++_generation;
    if (_closed) return Future.value();
    currentId = id;
    error = null;
    position = Duration.zero;
    duration = Duration.zero;
    phase = OfficeVoicePlaybackPhase.loading;
    _notify();
    // Copy untrusted mutable caller buffers before awaiting platform work.
    final input = Uint8List.fromList(bytes);
    return serial(() async {
      try {
        await _cleanup();
        if (_closed || generation != _generation || !isCurrent()) return;
        if (!await _focus.reservePlayback(this, stop)) {
          throw const OfficeVoiceException('audio_busy', '会议或录音期间暂不能播放语音');
        }
        if (!_current(generation)) return;
        final clip = OfficeVoiceClip.fromWav(input, maxBytes: maxBytes);
        duration = clip.duration;
        _source = await _storage.createPlayback(clip.bytes);
        if (!_current(generation)) {
          await _cleanup();
          return;
        }
        _subscriptions.add(
          _driver.positions.listen((value) {
            if (_current(generation)) {
              position = value < Duration.zero
                  ? Duration.zero
                  : value > duration
                  ? duration
                  : value;
              _notify();
            }
          }, onError: (Object _) => _failed(generation)),
        );
        _subscriptions.add(
          _driver.durations.listen((value) {
            // Header-derived duration is authoritative; player duration is not
            // allowed to replace it with a requested or guessed sample rate.
            if (_current(generation) && value < Duration.zero) {
              _failed(generation);
            }
          }, onError: (Object _) => _failed(generation)),
        );
        _subscriptions.add(
          _driver.states.listen((state) {
            if (!_current(generation)) return;
            if (state == OfficeVoiceDriverPlaybackState.completed) {
              unawaited(
                _background(
                  serial(() async {
                    if (!_current(generation)) return;
                    await _cleanup();
                    position = duration;
                    phase = OfficeVoicePlaybackPhase.completed;
                    _notify();
                  }),
                ),
              );
            } else if (state == OfficeVoiceDriverPlaybackState.paused) {
              phase = OfficeVoicePlaybackPhase.paused;
              _notify();
            }
          }, onError: (Object _) => _failed(generation)),
        );
        await _driver.play(_source!);
        if (!_current(generation)) {
          await _cleanup();
          return;
        }
        phase = OfficeVoicePlaybackPhase.playing;
        _guard = Timer.periodic(const Duration(milliseconds: 150), (_) {
          if (!_current(generation)) unawaited(_background(stop()));
        });
        _notify();
      } catch (failure) {
        await _cleanup();
        if (!_closed && generation == _generation) {
          phase = OfficeVoicePlaybackPhase.error;
          error = failure is OfficeVoiceException
              ? failure.message
              : '语音播放失败，请重试';
          _notify();
        }
      }
    });
  }

  void _failed(int generation) {
    if (!_current(generation)) return;
    unawaited(
      _background(
        serial(() async {
          if (!_current(generation)) return;
          await _cleanup();
          phase = OfficeVoicePlaybackPhase.error;
          error = '语音播放中断，请重试';
          _notify();
        }),
      ),
    );
  }

  Future<void> _control(Future<void> Function(int generation) action) {
    final generation = _generation;
    return serial(() async {
      if (!_current(generation)) return;
      try {
        await action(generation);
      } catch (_) {
        await _cleanup();
        if (!_closed && generation == _generation) {
          phase = OfficeVoicePlaybackPhase.error;
          error = '语音播放操作失败，请重试';
          _notify();
        }
      }
    });
  }

  Future<void> pause() => _control((generation) async {
    if (phase != OfficeVoicePlaybackPhase.playing) return;
    await _driver.pause();
    if (_current(generation)) {
      phase = OfficeVoicePlaybackPhase.paused;
      _notify();
    }
  });
  Future<void> resume() => _control((generation) async {
    if (phase != OfficeVoicePlaybackPhase.paused) return;
    await _driver.resume();
    if (_current(generation)) {
      phase = OfficeVoicePlaybackPhase.playing;
      _notify();
    }
  });
  Future<void> seek(Duration value) => _control((generation) async {
    if (_source == null) return;
    final bounded = value < Duration.zero
        ? Duration.zero
        : value > duration
        ? duration
        : value;
    await _driver.seek(bounded);
    if (_current(generation)) {
      position = bounded;
      _notify();
    }
  });
  Future<void> stop() {
    ++_generation;
    currentId = null;
    position = Duration.zero;
    duration = Duration.zero;
    phase = OfficeVoicePlaybackPhase.idle;
    error = null;
    _notify();
    return serial(_cleanup);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_background(stop()));
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    return _closing = () async {
      try {
        await stop();
      } finally {
        try {
          await _driver.dispose();
          _focus.releasePlayback(this);
        } finally {
          await _storage.close();
        }
      }
    }();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}
