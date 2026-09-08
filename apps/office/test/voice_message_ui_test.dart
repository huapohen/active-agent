import 'dart:async';
import 'dart:typed_data';

import 'package:active_office/office_state.dart';
import 'package:active_office/voice_audio.dart';
import 'package:active_office/ui/attachments.dart';
import 'package:active_office/ui/voice_composer.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversation_composer_alignment_test.dart'
    show ComposerOffice, mountComposer, input;

Uint8List voiceUiWav() {
  final bytes = Uint8List(44 + 64000), data = ByteData(44 + 64000);
  void ascii(int at, String text) =>
      bytes.setRange(at, at + text.length, text.codeUnits);
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, 64000, Endian.little);
  bytes.setAll(0, data.buffer.asUint8List());
  ascii(0, 'RIFF');
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  ascii(36, 'data');
  return bytes;
}

class UiVoiceStorage implements OfficeVoiceStorage {
  final Uint8List bytes = voiceUiWav();
  int released = 0;
  @override
  Future<String> createRecordingPath() async => 'owned-recording.wav';
  @override
  Future<Uint8List> readRecording(
    String location, {
    required int maxBytes,
  }) async => bytes;
  @override
  Future<void> releaseRecording(String location) async {
    released++;
  }

  @override
  Future<OfficeVoicePlaybackSource> createPlayback(Uint8List bytes) async =>
      const OfficeVoicePlaybackSource('owned-playback.wav');
  @override
  Future<void> releasePlayback(OfficeVoicePlaybackSource source) async {
    released++;
  }

  @override
  Future<void> close() async {}
}

class UiRecorderDriver implements OfficeVoiceRecorderDriver {
  final levels = StreamController<double>.broadcast();
  final changes = StreamController<OfficeVoiceDriverRecordState>.broadcast();
  Completer<bool>? permission;
  Completer<String?>? stopGate;
  bool allowed = true;
  int starts = 0, requests = 0, cancels = 0;
  @override
  Future<bool> hasPermission({required bool request}) async {
    requests++;
    return permission?.future ?? allowed;
  }

  @override
  Future<bool> supportsWav() async => true;
  @override
  Future<void> start(String path) async {
    starts++;
  }

  @override
  Future<String?> stop() async => stopGate?.future ?? 'owned-recording.wav';
  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Stream<double> get amplitudes => levels.stream;
  @override
  Stream<OfficeVoiceDriverRecordState> get states => changes.stream;
  @override
  Future<void> dispose() async {
    await levels.close();
    await changes.close();
  }
}

class UiPlayerDriver implements OfficeVoicePlaybackDriver {
  final progress = StreamController<Duration>.broadcast();
  final lengths = StreamController<Duration>.broadcast();
  final changes = StreamController<OfficeVoiceDriverPlaybackState>.broadcast();
  int plays = 0, pauses = 0, resumes = 0, stops = 0;
  @override
  Future<void> play(OfficeVoicePlaybackSource source) async {
    plays++;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {
    resumes++;
  }

  @override
  Future<void> seek(Duration position) async {
    progress.add(position);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Stream<Duration> get positions => progress.stream;
  @override
  Stream<Duration> get durations => lengths.stream;
  @override
  Stream<OfficeVoiceDriverPlaybackState> get states => changes.stream;
  @override
  Future<void> dispose() async {
    await progress.close();
    await lengths.close();
    await changes.close();
  }
}

class VoiceUiOffice extends ComposerOffice {
  final focus = OfficeVoiceAudioFocus();
  final recorderDriver = UiRecorderDriver();
  final players = <UiPlayerDriver>[];
  final recorders = <OfficeVoiceRecorder>[];
  final media = <OfficeVoicePlayback>[];
  final voiceUploads = <Json>[], voiceSends = <Json>[], discarded = <Json>[];
  Completer<Json>? uploadGate;
  Completer<Uint8List>? downloadGate;
  bool uploadFails = false,
      sendFails = false,
      downloadFails = false,
      voiceEnabled = true;
  int sourceSelection = 0;
  @override
  int get conversationSelection => sourceSelection;
  void moveRoom(String id) {
    selectedRoomId = id;
    sourceSelection++;
    notifyListeners();
  }

  @override
  OfficeVoiceRecorder createVoiceRecorder(
    bool Function() isCurrent, {
    Duration maxDuration = const Duration(seconds: 60),
  }) {
    final recorder = OfficeVoiceRecorder(
      isCurrent: isCurrent,
      maxDuration: maxDuration,
      driver: recorderDriver,
      storage: UiVoiceStorage(),
      focus: focus,
    );
    recorders.add(recorder);
    return recorder;
  }

  @override
  OfficeVoicePlayback createVoicePlayback(bool Function() isCurrent) {
    final driver = UiPlayerDriver();
    final player = OfficeVoicePlayback(
      isCurrent: isCurrent,
      driver: driver,
      storage: UiVoiceStorage(),
      focus: focus,
    );
    players.add(driver);
    media.add(player);
    return player;
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/capabilities') {
      return {
        'voice_media': {
          'enabled': voiceEnabled,
          'max_duration_ms': 60000,
          'max_attachment_bytes': 12582912,
        },
      };
    }
    return super.officeRequest(path, method: method, data: data);
  }

  @override
  Future<Json> uploadVoiceAttachment(
    OfficeVoiceClip clip, {
    required String sourceRoomId,
    required int identityGeneration,
    required int conversationSelection,
    required String clientId,
  }) async {
    voiceUploads.add({
      'room': sourceRoomId,
      'generation': identityGeneration,
      'selection': conversationSelection,
      'client_id': clientId,
      'bytes': clip.bytes,
    });
    if (uploadFails) throw OfficeException(503, 'Upload failed');
    return uploadGate?.future ?? {'id': 'recording-1', 'room_id': sourceRoomId};
  }

  @override
  Future<Json> sendVoiceAttachment({
    required String attachmentId,
    required String sourceRoomId,
    required int identityGeneration,
    required int conversationSelection,
    required String clientId,
  }) async {
    voiceSends.add({
      'id': attachmentId,
      'room': sourceRoomId,
      'client_id': clientId,
    });
    if (sendFails) throw OfficeException(503, 'Unconfirmed send');
    return {'id': 'voice-message'};
  }

  @override
  Future<void> discardVoiceAttachment(
    Json attachment, {
    required int identityGeneration,
  }) async {
    discarded.add(attachment);
  }

  @override
  Future<Uint8List> getAttachmentBytes(Json attachment) async {
    if (downloadFails) throw OfficeException(503, 'Download failed');
    return downloadGate?.future ?? voiceUiWav();
  }

  @override
  void dispose() {
    for (final recorder in recorders) {
      recorder.dispose();
    }
    for (final player in media) {
      player.dispose();
    }
    super.dispose();
  }
}

Future<void> pumpVoice(WidgetTester tester) async {
  // Stream cancellation can finish on the real async queue. Let real media
  // futures settle before rendering; deliberately gated operations stay gated.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> tapVoice(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await pumpVoice(tester);
}

Future<void> recordUiClip(WidgetTester tester) async {
  await tapVoice(tester, 'composer-voice');
  await tapVoice(tester, 'voice-start');
  await tapVoice(tester, 'voice-stop');
}

Json voiceUiAttachment(String id) => {
  'id': id,
  'room_id': 'room-demo',
  'filename': '$id.wav',
  'mime_type': 'audio/wav',
  'audio': {'duration_ms': 2000},
  'status': 'active',
};

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'record preview send at $width preserves text and fixed tool positions',
      (tester) async {
        final state = VoiceUiOffice();
        await mountComposer(tester, state, width: width, mobile: true);
        await tester.enterText(input, 'Keep this text draft');
        await pumpVoice(tester);
        final keys = [
          'composer-emoji',
          'composer-mention',
          'composer-voice',
          'composer-images',
          'composer-format',
          'composer-agent',
          'composer-more',
        ];
        final before = {
          for (final key in keys)
            key: tester.getCenter(find.byKey(ValueKey(key))),
        };
        await tapVoice(tester, 'composer-voice');
        expect(state.recorderDriver.requests, 0);
        await tapVoice(tester, 'voice-start');
        expect(state.recorderDriver.starts, 1);
        state.recorderDriver.levels.add(-30);
        await pumpVoice(tester);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byKey(const ValueKey('voice-amplitude')),
              )
              .value,
          .5,
        );
        await tapVoice(tester, 'voice-stop');
        expect(
          state.recorders.single.phase,
          OfficeVoiceRecorderPhase.ready,
          reason: state.recorders.single.error,
        );
        expect(find.text('0:02'), findsOneWidget);
        await tapVoice(tester, 'voice-preview');
        expect(state.players.last.plays, 1);
        await tapVoice(tester, 'voice-preview');
        expect(state.players.last.pauses, 1);
        await tapVoice(tester, 'voice-send');
        expect(find.byType(OfficeVoiceComposer), findsNothing);
        expect(state.voiceSends.single['room'], 'room-demo');
        expect(
          tester.widget<TextField>(input).controller!.text,
          'Keep this text draft',
        );
        for (final key in keys) {
          expect(tester.getCenter(find.byKey(ValueKey(key))), before[key]);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cancel and denied permission never upload and leave a usable draft',
    (tester) async {
      final state = VoiceUiOffice()..recorderDriver.allowed = false;
      await mountComposer(tester, state, width: 390, mobile: true);
      await tester.enterText(input, 'draft');
      await tapVoice(tester, 'composer-voice');
      await tapVoice(tester, 'voice-start');
      expect(find.textContaining('麦克风权限'), findsOneWidget);
      expect(state.recorderDriver.starts, 0);
      await tapVoice(tester, 'voice-cancel');
      expect(state.voiceUploads, isEmpty);
      expect(tester.widget<TextField>(input).controller!.text, 'draft');
    },
  );

  testWidgets('late permission cannot cross identity or source room', (
    tester,
  ) async {
    final state = VoiceUiOffice()
      ..recorderDriver.permission = Completer<bool>();
    await mountComposer(tester, state, width: 390, mobile: true);
    await tapVoice(tester, 'composer-voice');
    await tapVoice(tester, 'voice-start');
    state.changeIdentity();
    await pumpVoice(tester);
    state.recorderDriver.permission!.complete(true);
    await pumpVoice(tester);
    expect(state.recorderDriver.starts, 0);
    expect(state.voiceUploads, isEmpty);
    expect(find.textContaining('身份或会话已变化'), findsOneWidget);
  });

  testWidgets(
    'upload failure retries original bytes and unconfirmed send retries same ID',
    (tester) async {
      final state = VoiceUiOffice()..uploadFails = true;
      await mountComposer(tester, state, width: 390, mobile: true);
      await recordUiClip(tester);
      await tapVoice(tester, 'voice-send');
      expect(state.voiceUploads, hasLength(1));
      expect(state.voiceSends, isEmpty);
      state.uploadFails = false;
      state.sendFails = true;
      await tapVoice(tester, 'voice-send');
      expect(state.voiceUploads, hasLength(2));
      expect(
        state.voiceUploads[0]['client_id'],
        state.voiceUploads[1]['client_id'],
      );
      expect(state.voiceUploads[0]['bytes'], state.voiceUploads[1]['bytes']);
      state.sendFails = false;
      await tapVoice(tester, 'voice-send');
      expect(state.voiceUploads, hasLength(2));
      expect(
        state.voiceSends[0]['client_id'],
        state.voiceSends[1]['client_id'],
      );
      expect(state.discarded, isEmpty);
    },
  );

  testWidgets(
    'late stop cannot revive a recording after leaving and reopening its room',
    (tester) async {
      final state = VoiceUiOffice()
        ..recorderDriver.stopGate = Completer<String?>();
      await mountComposer(tester, state, width: 390, mobile: true);
      await tapVoice(tester, 'composer-voice');
      await tapVoice(tester, 'voice-start');
      await tapVoice(tester, 'voice-stop');
      state.moveRoom('different-room');
      state.moveRoom('room-demo');
      state.recorderDriver.stopGate!.complete('owned-recording.wav');
      await pumpVoice(tester);
      expect(state.recorders.single.clip, isNull);
      expect(state.voiceSends, isEmpty);
      expect(find.byKey(const ValueKey('voice-send')), findsNothing);
    },
  );

  testWidgets(
    'desktop more entry respects disabled service before requesting microphone',
    (tester) async {
      final state = VoiceUiOffice()..voiceEnabled = false;
      await mountComposer(tester, state, width: 750);
      await tapVoice(tester, 'composer-more');
      await tester.tap(find.text('语音消息'));
      await pumpVoice(tester);
      expect(find.text('当前服务未开启语音消息。'), findsOneWidget);
      expect(state.recorders, isEmpty);
      expect(state.recorderDriver.requests, 0);
      state.voiceEnabled = true;
      await tester.tap(find.text('重试检查'));
      await pumpVoice(tester);
      expect(find.byKey(const ValueKey('voice-start')), findsOneWidget);
      expect(state.recorderDriver.requests, 0);
      await tapVoice(tester, 'voice-cancel');
    },
  );

  testWidgets(
    'late upload after room change is discarded without dispatching a message',
    (tester) async {
      final state = VoiceUiOffice()..uploadGate = Completer<Json>();
      await mountComposer(tester, state, width: 390, mobile: true);
      await recordUiClip(tester);
      await tapVoice(tester, 'voice-send');
      state.moveRoom('different-room');
      await pumpVoice(tester);
      state.uploadGate!.complete({'id': 'late-audio', 'room_id': 'room-demo'});
      await pumpVoice(tester);
      expect(state.voiceSends, isEmpty);
      expect(state.discarded.single['room_id'], 'room-demo');
    },
  );

  testWidgets(
    'background interruption cancels recording instead of sending it',
    (tester) async {
      final state = VoiceUiOffice();
      await mountComposer(tester, state, width: 390, mobile: true);
      await tapVoice(tester, 'composer-voice');
      await tapVoice(tester, 'voice-start');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpVoice(tester);
      expect(state.recorderDriver.cancels, greaterThan(0));
      expect(state.voiceUploads, isEmpty);
      expect(find.byKey(const ValueKey('voice-send')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpVoice(tester);
      await tapVoice(tester, 'voice-cancel');
    },
  );

  testWidgets(
    'audio bubbles play exclusively, pause, seek, retry and stop when removed',
    (tester) async {
      final state = VoiceUiOffice();
      addTearDown(state.dispose);
      Widget body(List<String> ids) => MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final id in ids)
                    MessageAttachment(
                      key: ValueKey(id),
                      state: state,
                      attachment: voiceUiAttachment(id),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(body(['a', 'b']));
      await pumpVoice(tester);
      final aSize = tester.getSize(
        find.byKey(const ValueKey('voice-message-a')),
      );
      await tapVoice(tester, 'voice-play-a');
      expect(state.voicePlayback.phase, OfficeVoicePlaybackPhase.playing);
      expect(
        tester.getSize(find.byKey(const ValueKey('voice-message-a'))),
        aSize,
      );
      await tapVoice(tester, 'voice-play-a');
      expect(state.voicePlayback.phase, OfficeVoicePlaybackPhase.paused);
      tester
          .widget<Slider>(find.byKey(const ValueKey('voice-seek-a')))
          .onChanged!(1000);
      await pumpVoice(tester);
      expect(state.voicePlayback.position, const Duration(seconds: 1));
      await tapVoice(tester, 'voice-play-b');
      expect(state.voiceAttachmentId, 'b');
      expect(state.players.single.plays, 2);
      state.downloadFails = true;
      await tapVoice(tester, 'voice-play-a');
      expect(find.byKey(const ValueKey('voice-play-error-a')), findsOneWidget);
      state.downloadFails = false;
      await tapVoice(tester, 'voice-play-a');
      expect(state.players.single.plays, 3);
      state.players.single.changes.add(
        OfficeVoiceDriverPlaybackState.completed,
      );
      await pumpVoice(tester);
      expect(state.voicePlayback.phase, OfficeVoicePlaybackPhase.completed);
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('voice-seek-a')))
            .onChanged,
        isNull,
      );
      await tapVoice(tester, 'voice-play-a');
      expect(state.players.single.plays, 4);
      await tester.pumpWidget(body(['b']));
      await pumpVoice(tester);
      expect(state.voicePlayback.phase, OfficeVoicePlaybackPhase.idle);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late authenticated download cannot play after an account switch',
    (tester) async {
      final state = VoiceUiOffice()..downloadGate = Completer<Uint8List>();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: MessageAttachment(
                state: state,
                attachment: voiceUiAttachment('late'),
              ),
            ),
          ),
        ),
      );
      await pumpVoice(tester);
      await tapVoice(tester, 'voice-play-late');
      state.changeIdentity();
      state.downloadGate!.complete(voiceUiWav());
      await pumpVoice(tester);
      expect(state.players.single.plays, 0);
      expect(state.voiceAttachmentId, isNull);
    },
  );
}
