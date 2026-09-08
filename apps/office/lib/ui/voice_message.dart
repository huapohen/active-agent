import 'dart:async';

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import '../voice_audio.dart';
import 'office_theme.dart';
import 'voice_composer.dart' show officeVoiceTime;

class OfficeVoiceMessage extends StatefulWidget {
  const OfficeVoiceMessage({
    super.key,
    required this.state,
    required this.attachment,
    this.onDownload,
    this.saving = false,
  });
  final OfficeState state;
  final Json attachment;
  final VoidCallback? onDownload;
  final bool saving;

  @override
  State<OfficeVoiceMessage> createState() => _OfficeVoiceMessageState();
}

class _OfficeVoiceMessageState extends State<OfficeVoiceMessage> {
  bool _pageActive = true;
  String get _id => str(widget.attachment['id']);
  bool get _available =>
      (widget.attachment['status'] ??
          widget.attachment['availability'] ??
          'active') ==
      'active';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageActive =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false;
    if (!_pageActive) {
      unawaited(widget.state.stopVoicePlayback(attachmentId: _id));
    }
  }

  @override
  void didUpdateWidget(covariant OfficeVoiceMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state ||
        oldWidget.attachment['id'] != widget.attachment['id'] ||
        !_available) {
      unawaited(
        oldWidget.state.stopVoicePlayback(
          attachmentId: str(oldWidget.attachment['id']),
        ),
      );
    }
  }

  @override
  void dispose() {
    unawaited(widget.state.stopVoicePlayback(attachmentId: _id));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final player = state.voicePlayback;
    return AnimatedBuilder(
      animation: Listenable.merge([state, player]),
      builder: (context, _) {
        final active = state.voiceAttachmentId == _id;
        final playing =
            active && player.phase == OfficeVoicePlaybackPhase.playing;
        final loading =
            active &&
            (state.voiceLoading ||
                player.phase == OfficeVoicePlaybackPhase.loading);
        final error = active ? state.voicePlaybackError ?? player.error : null;
        final audio = widget.attachment['audio'];
        final milliseconds = audio is Map
            ? (audio['duration_ms'] as num?)?.ceil() ?? 0
            : 0;
        final duration = Duration(milliseconds: milliseconds);
        final position = active ? player.position : Duration.zero;
        return Container(
          key: ValueKey('voice-message-$_id'),
          constraints: const BoxConstraints(maxWidth: 270),
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .65),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xffe2e7ef)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: ValueKey('voice-play-$_id'),
                    tooltip: playing
                        ? '暂停语音'
                        : error == null
                        ? '播放语音'
                        : '重试播放',
                    onPressed: !_available || !_pageActive || loading
                        ? null
                        : () async {
                            try {
                              await state.playVoiceAttachment(
                                widget.attachment,
                              );
                            } catch (_) {
                              // A stale attachment action cannot start audio.
                            }
                          },
                    icon: loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            playing ? Icons.pause : Icons.play_arrow_rounded,
                            color: accentColor,
                          ),
                  ),
                  const Icon(Icons.graphic_eq, size: 21, color: mutedColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      active
                          ? '${officeVoiceTime(position)} / ${officeVoiceTime(duration)}'
                          : officeVoiceTime(duration),
                      key: ValueKey('voice-time-$_id'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (widget.onDownload != null)
                    IconButton(
                      tooltip: '下载语音',
                      onPressed: widget.saving ? null : widget.onDownload,
                      icon: widget.saving
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined, size: 18),
                    ),
                ],
              ),
              SizedBox(
                height: 26,
                child: Slider(
                  key: ValueKey('voice-seek-$_id'),
                  min: 0,
                  max: milliseconds.toDouble().clamp(1, double.infinity),
                  value: position.inMilliseconds.toDouble().clamp(
                    0,
                    milliseconds.toDouble().clamp(1, double.infinity),
                  ),
                  onChanged:
                      active &&
                          !loading &&
                          _available &&
                          _pageActive &&
                          (player.phase == OfficeVoicePlaybackPhase.playing ||
                              player.phase == OfficeVoicePlaybackPhase.paused)
                      ? (value) =>
                            player.seek(Duration(milliseconds: value.round()))
                      : null,
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Text(
                    '语音暂时无法播放，点击播放可重试。',
                    key: ValueKey('voice-play-error-$_id'),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
