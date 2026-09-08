import 'dart:async';

import 'package:active_office/meeting_controller.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/voice_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'voice_audio_service_test.dart'
    show FakeVoiceRecorderDriver, MemoryVoiceStorage;

class _Renderer implements RTCVideoRenderer {
  int initialized = 0, disposed = 0;
  MediaStream? source;
  @override
  Future<void> initialize() async => initialized++;
  @override
  Future<void> dispose() async => disposed++;
  @override
  MediaStream? get srcObject => source;
  @override
  set srcObject(MediaStream? stream) => source = stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Track extends MediaStreamTrack {
  int stopped = 0;
  Completer<void>? stopGate;
  Object? stopError;
  @override
  String get kind => 'audio';
  @override
  Future<void> stop() async {
    stopped++;
    if (stopGate != null) await stopGate!.future;
    if (stopError != null) throw stopError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Stream extends MediaStream {
  _Stream(this.track) : super('captured-media', 'test');
  final _Track track;
  int disposed = 0;
  @override
  List<MediaStreamTrack> getTracks() => [track];
  @override
  List<MediaStreamTrack> getAudioTracks() => [track];
  @override
  List<MediaStreamTrack> getVideoTracks() => [];
  @override
  Future<void> dispose() async => disposed++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Office extends OfficeState {
  final details = <String>[], joins = <String>[], leaves = <Json>[];
  final detailGates = <String, Completer<void>>{},
      joinGates = <String, Completer<void>>{};
  final polls = <Completer<Json>>[];
  bool failDetails = false;
  @override
  Future<Json> meetingDetail(String id) async {
    details.add(id);
    if (detailGates[id] != null) await detailGates[id]!.future;
    if (failDetails) throw OfficeException(404, '会议不存在');
    return {
      'meeting': {'id': id},
    };
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    final id = path.split('/')[2];
    if (path.endsWith('/join')) {
      joins.add(id);
      if (joinGates[id] != null) await joinGates[id]!.future;
      return {
        'meeting': {'id': id},
        'session_id': 'session-$id',
        'participants': <Json>[],
        'peers': <Json>[],
        'cursor': 0,
      };
    }
    if (path.endsWith('/leave')) {
      leaves.add({'meeting': id, ...?data});
      return {};
    }
    if (path.endsWith('/heartbeat')) return {'participants': <Json>[]};
    if (path.contains('/signals?')) {
      final gate = Completer<Json>();
      polls.add(gate);
      return gate.future;
    }
    throw StateError('unexpected request: $path');
  }

  @override
  void dispose() {
    for (final gate in polls) {
      if (!gate.isCompleted) {
        gate.complete({
          'participants': <Json>[],
          'signals': <Json>[],
          'cursor': 0,
        });
      }
    }
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('join waits for pending voice permission cancellation and never requests meeting capture', () async {
    final focus = OfficeVoiceAudioFocus();
    final voiceDriver = FakeVoiceRecorderDriver()
      ..permissionGate = Completer<bool>();
    final voice = OfficeVoiceRecorder(
      isCurrent: () => true,
      driver: voiceDriver,
      storage: MemoryVoiceStorage(),
      focus: focus,
    );
    final office = _Office(), renderer = _Renderer();
    var captureRequests = 0;
    final media = MeetingMediaController(
      audioFocus: focus,
      localRenderer: renderer,
      captureUserMedia: (_) async {
        captureRequests++;
        throw StateError('join must not capture');
      },
    );
    final recording = voice.startFromUserGesture();
    await flush();
    final join = media.join(office, 'a');
    await flush();
    expect(focus.meetingActive, isTrue);
    expect(office.details, isEmpty);
    voiceDriver.permissionGate!.complete(true);
    expect(await recording, isFalse);
    await join;
    expect(media.localSessionId, 'session-a');
    expect(captureRequests, 0);
    expect(voiceDriver.startCalls, 0);
    await media.close();
    expect(focus.meetingActive, isFalse);
    expect(renderer.disposed, 1);
    media.dispose();
    await voice.close();
    voice.dispose();
    office.dispose();
  });

  test('a newer join invalidates a delayed older detail before any old membership request', () async {
    final office = _Office()..detailGates['a'] = Completer<void>();
    final focus = OfficeVoiceAudioFocus();
    final media = MeetingMediaController(
      audioFocus: focus,
      localRenderer: _Renderer(),
    );
    final first = media.join(office, 'a');
    await flush();
    final second = media.join(office, 'b');
    expect(media.connecting, isTrue);
    office.detailGates['a']!.complete();
    await first;
    await second;
    expect(office.joins, ['b']);
    expect(media.activeMeeting?['id'], 'b');
    expect(media.connecting, isFalse);
    expect(focus.meetingActive, isTrue);
    await media.close();
    media.dispose();
    office.dispose();
  });

  test(
    'leave during a delayed join cleans exactly its late server session',
    () async {
      final office = _Office()..joinGates['a'] = Completer<void>();
      final focus = OfficeVoiceAudioFocus();
      final media = MeetingMediaController(
        audioFocus: focus,
        localRenderer: _Renderer(),
      );
      final join = media.join(office, 'a');
      await flush();
      expect(office.joins, ['a']);
      final leave = media.leave();
      office.joinGates['a']!.complete();
      await join;
      await leave;
      expect(office.leaves, [
        {'meeting': 'a', 'session_id': 'session-a'},
      ]);
      expect(media.activeMeeting, isNull);
      expect(media.localSessionId, isNull);
      expect(focus.meetingActive, isFalse);
      await media.close();
      media.dispose();
      office.dispose();
    },
  );

  test('late microphone and delayed track shutdown hold focus before the next join can start', () async {
    final office = _Office(), focus = OfficeVoiceAudioFocus();
    final capture = Completer<MediaStream>();
    final track = _Track()..stopGate = Completer<void>();
    final stream = _Stream(track);
    final media = MeetingMediaController(
      audioFocus: focus,
      localRenderer: _Renderer(),
      captureUserMedia: (_) => capture.future,
    );
    await media.join(office, 'a');
    final mic = media.setMicrophone(true);
    await flush();
    final leave = media.leave();
    final next = media.join(office, 'b');
    await flush();
    expect(focus.meetingActive, isTrue);
    expect(office.joins, ['a']);
    capture.complete(stream);
    await flush();
    expect(track.stopped, 1);
    expect(focus.meetingActive, isTrue);
    expect(office.joins, ['a']);
    track.stopGate!.complete();
    await mic;
    await leave;
    await next;
    expect(stream.disposed, 1);
    expect(media.activeMeeting?['id'], 'b');
    expect(media.microphoneEnabled, isFalse);
    expect(focus.meetingActive, isTrue);
    expect(office.leaves, [
      {'meeting': 'a', 'session_id': 'session-a'},
    ]);
    await media.close();
    media.dispose();
    office.dispose();
  });

  test('failed native track shutdown keeps meeting focus reserved until retry succeeds', () async {
    final office = _Office(), focus = OfficeVoiceAudioFocus();
    final track = _Track()..stopError = StateError('track did not stop');
    final stream = _Stream(track);
    final media = MeetingMediaController(
      audioFocus: focus,
      localRenderer: _Renderer(),
      captureUserMedia: (_) async => stream,
    );
    await media.join(office, 'a');
    await media.setMicrophone(true);
    await expectLater(media.leave(), throwsStateError);
    expect(focus.meetingActive, isTrue);
    expect(stream.disposed, 0);
    expect(office.leaves, isEmpty);
    track.stopError = null;
    await media.leave();
    expect(focus.meetingActive, isFalse);
    expect(stream.disposed, 1);
    expect(office.leaves, [
      {'meeting': 'a', 'session_id': 'session-a'},
    ]);
    await media.close();
    media.dispose();
    office.dispose();
  });

  for (final changed in ['generation', 'endpoint', 'principal']) {
    test(
      'failed shutdown retry does not send old leave after $changed changes',
      () async {
        final office = _Office()
          ..endpoint = 'http://original.office.test'
          ..me = {'id': 'original-person'};
        final focus = OfficeVoiceAudioFocus();
        final track = _Track()..stopError = StateError('track did not stop');
        final media = MeetingMediaController(
          audioFocus: focus,
          localRenderer: _Renderer(),
          captureUserMedia: (_) async => _Stream(track),
        );
        await media.join(office, 'a');
        await media.setMicrophone(true);
        await expectLater(media.leave(), throwsStateError);
        if (changed == 'generation') {
          office.disconnect();
          office.endpoint = 'http://original.office.test';
          office.me = {'id': 'original-person'};
        } else if (changed == 'endpoint') {
          office.endpoint = 'http://different.office.test';
        } else {
          office.me = {'id': 'different-person'};
        }
        track.stopError = null;
        await media.leave();
        expect(focus.meetingActive, isFalse);
        expect(office.leaves, isEmpty);
        await media.join(office, 'b');
        await media.close();
        expect(office.leaves, [
          {'meeting': 'b', 'session_id': 'session-b'},
        ]);
        media.dispose();
        office.dispose();
      },
    );
  }

  test(
    'join failure releases its lease and allows voice recording again',
    () async {
      final office = _Office()..failDetails = true;
      final focus = OfficeVoiceAudioFocus();
      final media = MeetingMediaController(
        audioFocus: focus,
        localRenderer: _Renderer(),
      );
      await media.join(office, 'missing');
      expect(media.error, '会议不存在');
      expect(media.connecting, isFalse);
      expect(focus.meetingActive, isFalse);
      final driver = FakeVoiceRecorderDriver();
      final voice = OfficeVoiceRecorder(
        isCurrent: () => true,
        driver: driver,
        storage: MemoryVoiceStorage(),
        focus: focus,
      );
      expect(await voice.startFromUserGesture(), isTrue);
      await voice.close();
      voice.dispose();
      await media.close();
      media.dispose();
      office.dispose();
    },
  );
  test(
    'close waits for a pending capture and disposes its renderer exactly once',
    () async {
      final office = _Office(),
          focus = OfficeVoiceAudioFocus(),
          renderer = _Renderer();
      final capture = Completer<MediaStream>();
      final stream = _Stream(_Track());
      final media = MeetingMediaController(
        audioFocus: focus,
        localRenderer: renderer,
        captureUserMedia: (_) => capture.future,
      );
      await media.join(office, 'a');
      final mic = media.setMicrophone(true);
      await flush();
      final closing = media.close();
      await flush();
      expect(focus.meetingActive, isTrue);
      expect(renderer.disposed, 0);
      capture.complete(stream);
      await mic;
      await closing;
      expect(stream.track.stopped, 1);
      expect(stream.disposed, 1);
      expect(focus.meetingActive, isFalse);
      expect(renderer.disposed, 1);
      await media.close();
      media.dispose();
      expect(renderer.disposed, 1);
      office.dispose();
    },
  );
}
