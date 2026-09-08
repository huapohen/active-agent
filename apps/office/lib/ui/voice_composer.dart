import 'dart:async';

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import '../voice_audio.dart';
import 'office_theme.dart';
import 'office_dialogs.dart' show friendlyError;

String officeVoiceTime(Duration duration) {
  final seconds = duration.inMicroseconds < 0
      ? 0
      : (duration.inMicroseconds / Duration.microsecondsPerSecond).ceil();
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

Future<bool?> showOfficeVoiceComposer(BuildContext context, OfficeState state) {
  final roomId = state.selectedRoomId;
  if (roomId == null || state.me == null) return Future.value(false);
  return showDialog<bool>(
    context: context,
    builder: (_) => OfficeVoiceComposer(state: state, roomId: roomId),
  );
}

/// Recording has its own route. It never replaces the text controller or
/// changes the fixed composer toolbar when recording or sending starts.
class OfficeVoiceComposer extends StatefulWidget {
  const OfficeVoiceComposer({
    super.key,
    required this.state,
    required this.roomId,
  });
  final OfficeState state;
  final String roomId;

  @override
  State<OfficeVoiceComposer> createState() => _OfficeVoiceComposerState();
}

class _OfficeVoiceComposerState extends State<OfficeVoiceComposer>
    with WidgetsBindingObserver {
  late final int _generation, _selection;
  late final String _endpoint, _principal;
  OfficeVoiceRecorder? _recorder;
  OfficeVoicePlayback? _preview;
  bool _closed = false, _invalid = false, _background = false;
  bool _loading = true, _sending = false, _sendAttempted = false;
  int _operation = 0;
  String? _error, _uploadId, _messageId;
  Json? _uploaded;
  Duration _limit = const Duration(seconds: 60);
  int _maxBytes = 12 * 1024 * 1024;
  OfficeState get s => widget.state;
  bool get _sameIdentity =>
      s.identityGeneration == _generation &&
      s.endpoint == _endpoint &&
      personId(s.me ?? {}) == _principal;
  bool get _current =>
      mounted &&
      !_closed &&
      !_invalid &&
      _sameIdentity &&
      s.selectedRoomId == widget.roomId &&
      s.conversationSelection == _selection;
  bool get _mediaCurrent => _current && !_background;

  void _cleanupInBackground(Future<void>? operation) {
    if (operation == null) return;
    unawaited(() async {
      try {
        await operation;
      } catch (_) {
        // Device/storage failures must not escape a lifecycle callback or
        // replace the original identity fence. The audio service retains its
        // own focus lease when a device cannot be confirmed stopped.
        if (!mounted || _closed || _invalid) return;
        setState(() => _error = '语音设备清理失败，请关闭页面后重试。');
      }
    }());
  }

  @override
  void initState() {
    super.initState();
    _generation = s.identityGeneration;
    _selection = s.conversationSelection;
    _endpoint = s.endpoint;
    _principal = personId(s.me ?? {});
    WidgetsBinding.instance.addObserver(this);
    s.addListener(_scopeChanged);
    _loadCapabilities();
  }

  void _scopeChanged() {
    if (!_current && !_invalid && mounted) {
      _invalid = true;
      _operation++;
      _cleanupInBackground(_recorder?.close());
      _cleanupInBackground(_preview?.close());
      unawaited(_discardUnsubmitted());
      setState(() {
        _sending = false;
        _loading = false;
        _error = '身份或会话已变化，这段录音不能发送。';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) setState(() => _background = false);
      if (_current && _recorder == null && !_loading) _loadCapabilities();
      return;
    }
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    _background = true;
    _operation++;
    _cleanupInBackground(_recorder?.cancel());
    _cleanupInBackground(_preview?.stop());
    unawaited(_discardUnsubmitted());
    if (mounted) {
      setState(() {
        _sending = false;
        _loading = false;
        _error = _sendAttempted
            ? '发送已提交，结果尚未确认。请回到原会话核对。'
            : '应用已切到后台，录音已取消。返回后可重新录制。';
      });
    }
  }

  Future<void> _loadCapabilities() async {
    final operation = ++_operation;
    if (mounted) setState(() => _loading = true);
    try {
      final result = await s.officeRequest('/capabilities');
      if (!_current || operation != _operation) return;
      final media = result['voice_media'];
      if (media is! Map || media['enabled'] != true) {
        throw OfficeException(503, '当前服务未开启语音消息。');
      }
      final milliseconds = (media['max_duration_ms'] as num?)?.toInt() ?? 0;
      if (milliseconds <= 0) {
        throw OfficeException(503, '语音服务配置暂不可用。');
      }
      _limit = Duration(milliseconds: milliseconds.clamp(1, 60000));
      _maxBytes =
          ((media['max_attachment_bytes'] as num?)?.toInt() ?? 12 * 1024 * 1024)
              .clamp(1, 12 * 1024 * 1024);
      _recorder = s.createVoiceRecorder(
        () => _mediaCurrent,
        maxDuration: _limit,
      );
      _preview = s.createVoicePlayback(() => _mediaCurrent);
      _error = null;
    } catch (e) {
      if (_current && operation == _operation) _error = friendlyError(e);
    } finally {
      if (_current && operation == _operation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _start() async {
    if (!_mediaCurrent || _sending || _sendAttempted) return;
    await _preview?.stop();
    await _discardUnsubmitted();
    if (!_mediaCurrent) return;
    setState(() {
      _error = null;
      _uploadId = OfficeState.newClientId();
      _messageId = OfficeState.newClientId();
    });
    await _recorder?.startFromUserGesture();
  }

  Future<void> _stop() async {
    if (!_mediaCurrent || _sending) return;
    await _recorder?.stop();
  }

  Future<void> _listen() async {
    final clip = _recorder?.clip, preview = _preview;
    if (!_mediaCurrent || clip == null || preview == null || _sending) return;
    if (preview.phase == OfficeVoicePlaybackPhase.playing) {
      await preview.pause();
    } else if (preview.phase == OfficeVoicePlaybackPhase.paused) {
      await preview.resume();
    } else {
      await preview.playBytes(id: _uploadId ?? 'preview', bytes: clip.bytes);
    }
  }

  Future<void> _send() async {
    final clip = _recorder?.clip;
    if (!_mediaCurrent || _sending || clip == null) return;
    if (clip.bytes.length > _maxBytes || clip.duration > _limit) {
      setState(() => _error = '录音超过当前服务限制，请重新录制。');
      return;
    }
    final operation = ++_operation;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _preview?.stop();
      if (!_mediaCurrent || operation != _operation) return;
      if (_uploaded == null) {
        final record = await s.uploadVoiceAttachment(
          clip,
          sourceRoomId: widget.roomId,
          identityGeneration: _generation,
          conversationSelection: _selection,
          clientId: _uploadId ??= OfficeState.newClientId(),
        );
        if (!_mediaCurrent || operation != _operation) {
          // No message was dispatched for this returned upload. Clean up only
          // under its original identity, never under a newly signed-in user.
          if (_sameIdentity) {
            await s.discardVoiceAttachment(
              record,
              identityGeneration: _generation,
            );
          }
          return;
        }
        _uploaded = record;
      }
      if (!_mediaCurrent || operation != _operation) return;
      setState(() => _sendAttempted = true);
      await s.sendVoiceAttachment(
        attachmentId: str(_uploaded!['id']),
        sourceRoomId: widget.roomId,
        identityGeneration: _generation,
        conversationSelection: _selection,
        clientId: _messageId ??= OfficeState.newClientId(),
      );
      if (mounted && _current && operation == _operation) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (_current && operation == _operation) {
        setState(
          () => _error = _sendAttempted
              ? '${friendlyError(e)}。重试会沿用同一条语音的发送编号。'
              : '${friendlyError(e)}。录音仍在，可重试上传。',
        );
      }
    } finally {
      if (_current && operation == _operation) setState(() => _sending = false);
    }
  }

  Future<void> _discardUnsubmitted() async {
    final attachment = _uploaded;
    if (_sendAttempted || attachment == null) return;
    _uploaded = null;
    if (!_sameIdentity) return;
    try {
      await s.discardVoiceAttachment(
        attachment,
        identityGeneration: _generation,
      );
    } catch (_) {
      // Cleanup failure must not resume recording or send an abandoned draft.
    }
  }

  @override
  void dispose() {
    _closed = true;
    _operation++;
    s.removeListener(_scopeChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_discardUnsubmitted());
    _cleanupInBackground(_recorder?.close());
    _cleanupInBackground(_preview?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([?_recorder, ?_preview]),
    builder: (context, _) {
      final recorder = _recorder, preview = _preview;
      final clip = recorder?.clip;
      final recording = recorder?.phase == OfficeVoiceRecorderPhase.recording;
      final processing =
          recorder?.phase == OfficeVoiceRecorderPhase.requestingPermission ||
          recorder?.phase == OfficeVoiceRecorderPhase.stopping;
      final busy = _loading || _sending || processing;
      final error = _error ?? recorder?.error ?? preview?.error;
      return AlertDialog(
        key: const ValueKey('voice-composer-panel'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        title: Row(
          children: [
            const Expanded(child: Text('语音消息')),
            IconButton(
              key: const ValueKey('voice-close'),
              tooltip: _sendAttempted ? '关闭语音面板' : '关闭并取消录音',
              onPressed: () => Navigator.pop(context, false),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '最长 ${officeVoiceTime(_limit)}，录完可试听后发送。',
                  style: const TextStyle(fontSize: 12, color: mutedColor),
                ),
                const SizedBox(height: 18),
                Icon(
                  recording ? Icons.mic : Icons.mic_none,
                  size: 34,
                  color: recording ? Colors.redAccent : accentColor,
                ),
                const SizedBox(height: 10),
                Text(
                  officeVoiceTime(
                    clip?.duration ?? recorder?.elapsed ?? Duration.zero,
                  ),
                  key: const ValueKey('voice-duration'),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (recording) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    label: '麦克风实际音量',
                    child: LinearProgressIndicator(
                      key: const ValueKey('voice-amplitude'),
                      value: recorder?.amplitudeDbfs == null
                          ? 0
                          : ((recorder!.amplitudeDbfs! + 60) / 60).clamp(0, 1),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    recorder?.amplitudeDbfs == null ? '等待麦克风音量' : '正在录音',
                    style: const TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ],
                if (clip != null && !recording) ...[
                  const SizedBox(height: 10),
                  if (clip.truncated)
                    Text(
                      '已达到时长上限，保留前 ${officeVoiceTime(clip.duration)}。',
                      style: const TextStyle(fontSize: 12, color: mutedColor),
                    ),
                  Text(
                    '${officeVoiceTime(preview?.position ?? Duration.zero)} / ${officeVoiceTime(clip.duration)}',
                    key: const ValueKey('voice-preview-progress'),
                  ),
                  Slider(
                    key: const ValueKey('voice-preview-seek'),
                    value: (preview?.position.inMilliseconds ?? 0)
                        .toDouble()
                        .clamp(
                          0,
                          clip.duration.inMilliseconds.toDouble().clamp(
                            1,
                            double.infinity,
                          ),
                        ),
                    max: clip.duration.inMilliseconds.toDouble().clamp(
                      1,
                      double.infinity,
                    ),
                    onChanged:
                        !busy &&
                            _mediaCurrent &&
                            (preview?.phase ==
                                    OfficeVoicePlaybackPhase.playing ||
                                preview?.phase ==
                                    OfficeVoicePlaybackPhase.paused)
                        ? (value) => preview!.seek(
                            Duration(milliseconds: value.round()),
                          )
                        : null,
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('voice-preview'),
                    onPressed: busy || !_mediaCurrent ? null : _listen,
                    icon: Icon(
                      preview?.phase == OfficeVoicePlaybackPhase.playing
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    label: Text(
                      preview?.phase == OfficeVoicePlaybackPhase.playing
                          ? '暂停试听'
                          : '试听',
                    ),
                  ),
                ],
                if (busy) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                  Text(
                    _loading
                        ? '检查语音服务…'
                        : _sending
                        ? (_sendAttempted ? '发送语音…' : '上传录音…')
                        : recorder?.phase == OfficeVoiceRecorderPhase.stopping
                        ? '正在保存录音…'
                        : '正在请求麦克风权限…',
                  ),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error,
                      key: const ValueKey('voice-error'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                if (!_loading && recorder == null && !_invalid)
                  TextButton(
                    onPressed: _loadCapabilities,
                    child: const Text('重试检查'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('voice-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(_sendAttempted ? '关闭' : '取消'),
          ),
          if (recording)
            FilledButton.icon(
              key: const ValueKey('voice-stop'),
              onPressed: busy || !_mediaCurrent ? null : _stop,
              icon: const Icon(Icons.stop),
              label: const Text('停止录音'),
            )
          else if (recorder != null) ...[
            if (!_sendAttempted)
              TextButton(
                key: const ValueKey('voice-start'),
                onPressed: busy || !_mediaCurrent ? null : _start,
                child: Text(clip == null ? '开始录音' : '重新录制'),
              ),
            if (clip != null)
              FilledButton(
                key: const ValueKey('voice-send'),
                onPressed: busy || !_mediaCurrent ? null : _send,
                child: Text(_sendAttempted ? '重试发送' : '发送语音'),
              ),
          ],
        ],
      );
    },
  );
}
