import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:active_office/office_state.dart';
import 'package:active_office/voice_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'office_state_test.dart' show Service;

class VoiceProtocolService extends Service {
  VoiceProtocolService(super.kind);
  final List<http.Request> uploads = [],
      voiceSends = [],
      deletes = [],
      downloads = [];
  Completer<void>? uploadGate;
  bool loseVoiceResponse = false;
  @override
  Future<http.Response> call(http.Request request) async {
    final path = request.url.path.replaceFirst('/api/im', '');
    if (request.headers['authorization'] != 'Bearer private-test-identity') {
      return super.json({}, 401);
    }
    if (path == '/rooms/room-1/attachments' && request.method == 'POST') {
      uploads.add(request);
      await uploadGate?.future;
      return super.json({
        'attachment': {
          'id': 'audio-1',
          'mime_type': 'audio/wav',
          'audio': {'duration_ms': 2000},
        },
      });
    }
    if (path == '/rooms/room-1/attachments/audio-1' &&
        request.method == 'DELETE') {
      deletes.add(request);
      return super.json({});
    }
    if (path == '/rooms/room-1/attachments/audio-1/content') {
      downloads.add(request);
      return http.Response.bytes([1, 2, 3], 200);
    }
    if (path == '/rooms/room-1/messages' &&
        request.method == 'POST' &&
        (jsonDecode(request.body) as Map).containsKey('voice')) {
      voiceSends.add(request);
      if (loseVoiceResponse && voiceSends.length == 1) {
        throw http.ClientException('Ambiguous voice acknowledgement');
      }
      return super.json({
        'message': {
          'id': 'voice-1',
          'kind': 'voice',
          'voice': {'attachment_id': 'audio-1', 'duration_ms': 2000},
        },
      });
    }
    return super.call(request);
  }
}

void main() {
  final clip = OfficeVoiceClip(
    bytes: Uint8List.fromList([82, 73, 70, 70]),
    filename: 'voice.wav',
    duration: const Duration(seconds: 2),
  );
  Future<void> finish(OfficeState state) async {
    state.disconnect();
    state.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 130));
  }

  for (final kind in ['human', 'agent']) {
    test(
      '$kind voice upload and retry use authenticated native contract without guessed duration',
      () async {
        final service = VoiceProtocolService(kind)..loseVoiceResponse = true;
        final state = OfficeState(client: MockClient(service.call));
        await state.connect('http://localhost', 'private-test-identity');
        final generation = state.identityGeneration,
            selection = state.conversationSelection;
        final attachment = await state.uploadVoiceAttachment(
          clip,
          sourceRoomId: 'room-1',
          identityGeneration: generation,
          conversationSelection: selection,
          clientId: 'upload-intent',
        );
        final body = jsonDecode(service.uploads.single.body) as Map;
        expect(body, {
          'client_id': 'upload-intent',
          'filename': 'voice.wav',
          'mime_type': 'audio/wav',
          'data_base64': base64Encode(clip.bytes),
        });
        expect(attachment['room_id'], 'room-1');
        Future<Json> send() => state.sendVoiceAttachment(
          attachmentId: 'audio-1',
          sourceRoomId: 'room-1',
          identityGeneration: generation,
          conversationSelection: selection,
          clientId: 'message-intent',
        );
        await expectLater(send(), throwsA(isA<OfficeException>()));
        final message = await send();
        expect(message['kind'], 'voice');
        expect(
          service.voiceSends.map((r) => jsonDecode(r.body)),
          everyElement({
            'client_id': 'message-intent',
            'content': '',
            'voice': {'attachment_id': 'audio-1'},
          }),
        );
        await state.getAttachmentBytes(attachment);
        expect(
          service.downloads.single.headers['authorization'],
          'Bearer private-test-identity',
        );
        expect(service.downloads.single.url.query, isEmpty);
        await finish(state);
      },
    );
  }

  test('stale selection including reopening the original room never dispatches voice', () async {
    final service = VoiceProtocolService('human');
    final state = OfficeState(client: MockClient(service.call));
    await state.connect('http://localhost', 'private-test-identity');
    final generation = state.identityGeneration,
        selection = state.conversationSelection;
    await state.selectRoom('room-1');
    expect(state.conversationSelection, isNot(selection));
    await expectLater(
      state.sendVoiceAttachment(
        attachmentId: 'audio-1',
        sourceRoomId: 'room-1',
        identityGeneration: generation,
        conversationSelection: selection,
        clientId: 'stale',
      ),
      throwsA(isA<OfficeException>()),
    );
    expect(service.voiceSends, isEmpty);
    await finish(state);
  });

  test('late upload after disconnect cannot become a message or clean up as a new identity', () async {
    final service = VoiceProtocolService('human')
      ..uploadGate = Completer<void>();
    final state = OfficeState(client: MockClient(service.call));
    await state.connect('http://localhost', 'private-test-identity');
    final generation = state.identityGeneration;
    final upload = state.uploadVoiceAttachment(
      clip,
      sourceRoomId: 'room-1',
      identityGeneration: generation,
      conversationSelection: state.conversationSelection,
      clientId: 'old-upload',
    );
    final expected = expectLater(upload, throwsA(isA<OfficeException>()));
    await Future<void>.delayed(Duration.zero);
    state.disconnect();
    service.uploadGate!.complete();
    await expected;
    await state.discardVoiceAttachment({
      'id': 'audio-1',
      'room_id': 'room-1',
    }, identityGeneration: generation);
    expect(service.voiceSends, isEmpty);
    expect(service.deletes, isEmpty);
    await finish(state);
  });
}
