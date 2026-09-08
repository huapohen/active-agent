import 'package:active_office/ui/voice_composer.dart';
import 'package:active_office/voice_audio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversation_composer_alignment_test.dart' show mountComposer;
import 'voice_message_ui_test.dart'
    show
        VoiceUiOffice,
        UiRecorderDriver,
        UiPlayerDriver,
        UiVoiceStorage,
        pumpVoice,
        tapVoice,
        recordUiClip;

class FaultyRecorderDriver extends UiRecorderDriver {
  bool failCleanup = false;
  int cleanupAttempts = 0;
  @override
  Future<void> cancel() async {
    cleanupAttempts++;
    if (failCleanup) {
      throw StateError('Synthetic recorder cancellation failure');
    }
    await super.cancel();
  }

  @override
  Future<void> dispose() async {
    cleanupAttempts++;
    await super.dispose();
    if (failCleanup) throw StateError('Synthetic recorder disposal failure');
  }
}

class FaultyPlayerDriver extends UiPlayerDriver {
  bool failCleanup = false;
  int cleanupAttempts = 0;
  @override
  Future<void> stop() async {
    cleanupAttempts++;
    if (failCleanup) throw StateError('Synthetic player stop failure');
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    cleanupAttempts++;
    await super.dispose();
    if (failCleanup) throw StateError('Synthetic player disposal failure');
  }
}

class FaultyStorage extends UiVoiceStorage {
  bool failClose = false;
  int closeAttempts = 0;
  @override
  Future<void> close() async {
    closeAttempts++;
    if (failClose) throw StateError('Synthetic storage cleanup failure');
  }
}

class CleanupFailureOffice extends VoiceUiOffice {
  final failingRecorder = FaultyRecorderDriver();
  final failingPlayer = FaultyPlayerDriver();
  final recorderStorage = FaultyStorage();
  final previewStorage = FaultyStorage();

  void failDevices() {
    failingRecorder.failCleanup = true;
    failingPlayer.failCleanup = true;
  }

  @override
  OfficeVoiceRecorder createVoiceRecorder(
    bool Function() isCurrent, {
    Duration maxDuration = const Duration(seconds: 60),
  }) {
    final recorder = OfficeVoiceRecorder(
      isCurrent: isCurrent,
      maxDuration: maxDuration,
      driver: failingRecorder,
      storage: recorderStorage,
      focus: focus,
    );
    recorders.add(recorder);
    return recorder;
  }

  @override
  OfficeVoicePlayback createVoicePlayback(bool Function() isCurrent) {
    final player = OfficeVoicePlayback(
      isCurrent: isCurrent,
      driver: failingPlayer,
      storage: previewStorage,
      focus: focus,
    );
    players.add(failingPlayer);
    media.add(player);
    return player;
  }
}

void main() {
  for (final scope in ['identity', 'room']) {
    testWidgets(
      '$scope changes consume failed device disposal and retain the send fence',
      (tester) async {
        final state = CleanupFailureOffice();
        await mountComposer(tester, state, width: 390, mobile: true);
        await tapVoice(tester, 'composer-voice');
        await tapVoice(tester, 'voice-start');
        expect(state.failingRecorder.starts, 1);
        state.failDevices();
        if (scope == 'identity') {
          state.changeIdentity();
        } else {
          state.moveRoom('different-room');
        }
        await pumpVoice(tester);
        expect(state.failingRecorder.cleanupAttempts, greaterThan(0));
        expect(state.failingPlayer.cleanupAttempts, greaterThan(0));
        expect(find.textContaining('身份或会话已变化'), findsOneWidget);
        expect(state.voiceUploads, isEmpty);
        expect(state.voiceSends, isEmpty);
        expect(find.byKey(const ValueKey('voice-send')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await pumpVoice(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'background cancellation errors become a safe message without sending or resuming capture',
    (tester) async {
      final state = CleanupFailureOffice();
      await mountComposer(tester, state, width: 390, mobile: true);
      await tapVoice(tester, 'composer-voice');
      await tapVoice(tester, 'voice-start');
      state.failDevices();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpVoice(tester);
      expect(find.text('语音设备清理失败，请关闭页面后重试。'), findsOneWidget);
      expect(state.failingRecorder.cleanupAttempts, greaterThan(0));
      expect(state.failingPlayer.cleanupAttempts, greaterThan(0));
      expect(state.voiceUploads, isEmpty);
      expect(state.voiceSends, isEmpty);
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpVoice(tester);
      expect(
        state.failingRecorder.starts,
        1,
        reason: 'foregrounding never restarts the microphone',
      );
      await tester.pumpWidget(const SizedBox());
      await pumpVoice(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing active preview consumes device and storage failures without setState after dispose',
    (tester) async {
      final state = CleanupFailureOffice();
      await mountComposer(tester, state, width: 390, mobile: true);
      await recordUiClip(tester);
      await tapVoice(tester, 'voice-preview');
      expect(state.failingPlayer.plays, 1);
      state.failDevices();
      state.recorderStorage.failClose = true;
      state.previewStorage.failClose = true;
      await tapVoice(tester, 'voice-cancel');
      expect(find.byType(OfficeVoiceComposer), findsNothing);
      expect(state.recorderStorage.closeAttempts, greaterThan(0));
      expect(state.previewStorage.closeAttempts, greaterThan(0));
      expect(state.voiceUploads, isEmpty);
      expect(state.voiceSends, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
