import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'office_state.dart';

class _Peer {
  _Peer(this.connection, this.renderer);
  final RTCPeerConnection connection;
  final RTCVideoRenderer renderer;
  final List<RTCIceCandidate> candidates = [];
  RTCRtpSender? audio, video;
  MediaStream? received;
  bool remoteReady = false;
}

/// Small-room mesh transport. The durable office stores membership and notes;
/// SDP, ICE and media remain ephemeral. Joining never opens capture devices.
class MeetingMediaController extends ChangeNotifier {
  OfficeState? _office;
  Json? activeMeeting;
  List<Json> participants = [];
  String? localSessionId;
  bool microphoneEnabled = false, cameraEnabled = false, sharing = false;
  bool connecting = false;
  String error = '';
  final Map<String, _Peer> _peers = {};
  final RTCVideoRenderer _local = RTCVideoRenderer();
  MediaStream? _audioStream, _cameraStream, _screenStream;
  Timer? _heartbeat;
  int _epoch = 0;
  bool _initialized = false, _disposed = false, _changingMedia = false;
  final String _deviceId = OfficeState.newClientId();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<Json> _request(String suffix, {String method = 'POST', Json? data}) {
    final office = _office, meeting = activeMeeting;
    if (office == null || meeting == null) throw OfficeException(410, '请先加入会议');
    return office.officeRequest(
      '/meetings/${meeting['id']}$suffix',
      method: method,
      data: data,
    );
  }

  Future<void> join(OfficeState office, String id) async {
    await leave();
    final epoch = ++_epoch;
    connecting = true;
    error = '';
    _office = office;
    _notify();
    try {
      if (!_initialized) {
        await _local.initialize();
        _initialized = true;
      }
      final detail = await office.meetingDetail(id);
      if (epoch != _epoch) return;
      activeMeeting = Json.from(detail['meeting']);
      final joined = await _request('/join', data: {'device_id': _deviceId});
      if (epoch != _epoch) return;
      activeMeeting = Json.from(joined['meeting']);
      localSessionId = joined['session_id'];
      participants = (joined['participants'] as List)
          .map((p) => Json.from(p))
          .toList();
      // The newcomer alone offers to existing peers. Pre-negotiated sendrecv
      // transceivers allow later capture toggles without offer glare.
      for (final participant in joined['peers'] as List) {
        final peerId = participant['session_id'] as String;
        final peer = await _peer(peerId, epoch, offerer: true);
        final offer = await peer.connection.createOffer();
        await peer.connection.setLocalDescription(offer);
        await _signal(peerId, 'offer', {'type': offer.type, 'sdp': offer.sdp});
      }
      if (epoch != _epoch) return;
      _heartbeat = Timer.periodic(
        const Duration(seconds: 12),
        (_) => unawaited(_beat(epoch)),
      );
      unawaited(_poll(epoch, (joined['cursor'] as num?)?.toInt() ?? 0));
    } catch (e) {
      if (epoch == _epoch) {
        await leave();
        error = e is OfficeException ? e.toString() : '无法加入媒体会议，请检查设备与网络后重试';
      }
    } finally {
      connecting = false;
      _notify();
    }
  }

  Map<String, dynamic> _configuration() {
    // Operators may provide trusted ICE services at build time. No public relay
    // or third-party STUN server is contacted by default.
    const configured = String.fromEnvironment(
      'OFFICE_ICE_SERVERS',
      defaultValue: '[]',
    );
    final parsed = jsonDecode(configured);
    if (parsed is! List) {
      throw const FormatException('ICE server list required');
    }
    return {'sdpSemantics': 'unified-plan', 'iceServers': parsed};
  }

  Future<_Peer> _peer(String id, int epoch, {bool offerer = false}) async {
    if (_peers.containsKey(id)) return _peers[id]!;
    final connection = await createPeerConnection(_configuration());
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final peer = _Peer(connection, renderer);
    if (epoch != _epoch) {
      await connection.close();
      await renderer.dispose();
      throw OfficeException(410, '会议已关闭');
    }
    _peers[id] = peer;
    connection.onIceCandidate = (candidate) {
      if (epoch != _epoch ||
          candidate.candidate == null ||
          candidate.candidate!.isEmpty) {
        return;
      }
      unawaited(
        _signal(id, 'candidate', candidate.toMap()).catchError((Object _) {
          if (epoch == _epoch) {
            error = '网络协商未完成，请重新加入会议';
            _notify();
          }
        }),
      );
    };
    connection.onTrack = (event) {
      if (epoch != _epoch) return;
      unawaited(_receiveTrack(peer, event, epoch));
    };
    connection.onConnectionState = (state) {
      if (epoch != _epoch) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        error = '媒体连接失败。同一网络可直连；跨网络部署需要配置 TURN 服务';
      }
      _notify();
    };
    if (offerer) {
      final audio = await connection.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      final video = await connection.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      peer.audio = audio.sender;
      peer.video = video.sender;
      await _attach(peer);
    }
    return peer;
  }

  Future<void> _receiveTrack(_Peer peer, RTCTrackEvent event, int epoch) async {
    if (event.streams.isNotEmpty) {
      peer.renderer.srcObject = event.streams.first;
    } else {
      // Track-only transceivers have no msid stream, especially in browsers.
      peer.received ??= await createLocalMediaStream(
        'remote-${OfficeState.newClientId()}',
      );
      if (epoch != _epoch) return;
      await peer.received!.addTrack(event.track);
      peer.renderer.srcObject = peer.received;
    }
    _notify();
  }

  Future<void> _attach(_Peer peer) async {
    await peer.audio?.replaceTrack(_audioStream?.getAudioTracks().firstOrNull);
    await peer.video?.replaceTrack(
      (_screenStream ?? _cameraStream)?.getVideoTracks().firstOrNull,
    );
  }

  Future<void> _signal(String to, String kind, Json payload) async {
    await _request(
      '/signals',
      data: {
        'session_id': localSessionId,
        'to': to,
        'kind': kind,
        'payload': payload,
      },
    );
  }

  Future<void> _handle(Json signal, int epoch) async {
    final id = signal['from'] as String;
    final peer = await _peer(id, epoch);
    final payload = Json.from(signal['payload']);
    if (signal['kind'] == 'candidate') {
      final candidate = RTCIceCandidate(
        payload['candidate'],
        payload['sdpMid'],
        payload['sdpMLineIndex'],
      );
      if (peer.remoteReady) {
        await peer.connection.addCandidate(candidate);
      } else {
        peer.candidates.add(candidate);
      }
      return;
    }
    await peer.connection.setRemoteDescription(
      RTCSessionDescription(payload['sdp'], payload['type']),
    );
    peer.remoteReady = true;
    for (final candidate in peer.candidates) {
      await peer.connection.addCandidate(candidate);
    }
    peer.candidates.clear();
    if (signal['kind'] == 'offer') {
      for (final transceiver in await peer.connection.getTransceivers()) {
        await transceiver.setDirection(TransceiverDirection.SendRecv);
        final kind = transceiver.receiver.track?.kind;
        if (kind == 'audio') peer.audio = transceiver.sender;
        if (kind == 'video') peer.video = transceiver.sender;
      }
      await _attach(peer);
      final answer = await peer.connection.createAnswer();
      await peer.connection.setLocalDescription(answer);
      await _signal(id, 'answer', {'type': answer.type, 'sdp': answer.sdp});
    }
  }

  Future<void> _syncParticipants(dynamic values) async {
    participants = (values as List).map((p) => Json.from(p)).toList();
    final present = participants.map((p) => p['session_id']).toSet();
    for (final id in _peers.keys.toList()) {
      if (!present.contains(id)) await _closePeer(_peers.remove(id)!);
    }
    _notify();
  }

  Future<void> _beat(int epoch) async {
    if (epoch != _epoch || localSessionId == null) return;
    try {
      final result = await _request(
        '/heartbeat',
        data: {
          'session_id': localSessionId,
          'audio': microphoneEnabled,
          'video': cameraEnabled,
          'sharing': sharing,
        },
      );
      if (epoch == _epoch) await _syncParticipants(result['participants']);
    } catch (e) {
      if (epoch == _epoch) await _lost(e);
    }
  }

  Future<void> _poll(int epoch, int cursor) async {
    while (epoch == _epoch && localSessionId != null && !_disposed) {
      try {
        final result = await _request(
          '/signals?session_id=${Uri.encodeQueryComponent(localSessionId!)}&after=$cursor&wait=20',
          method: 'GET',
        );
        if (epoch != _epoch) return;
        if (result['reset_required'] == true) {
          throw OfficeException(410, '会议连接已重置，请重新加入');
        }
        await _syncParticipants(result['participants']);
        for (final signal in result['signals'] as List) {
          if (epoch != _epoch) return;
          await _handle(Json.from(signal), epoch);
        }
        cursor = (result['cursor'] as num).toInt();
      } catch (e) {
        if (epoch == _epoch) await _lost(e);
        return;
      }
    }
  }

  Future<void> _lost(Object errorValue) async {
    await leave();
    error = errorValue is OfficeException
        ? errorValue.toString()
        : '媒体协商中断，请重新加入会议';
    _notify();
  }

  Future<void> _change(Future<void> Function() action) async {
    if (_changingMedia || localSessionId == null) return;
    final epoch = _epoch;
    _changingMedia = true;
    error = '';
    try {
      await action();
      if (epoch != _epoch) {
        await _stopCapture();
        return;
      }
      _local.srcObject = _screenStream ?? _cameraStream;
      for (final peer in _peers.values.toList()) {
        await _attach(peer);
      }
      await _beat(epoch);
    } catch (_) {
      error = '设备权限未允许或设备不可用，请检查系统权限后重试';
    } finally {
      _changingMedia = false;
      _notify();
    }
  }

  Future<void> setMicrophone(bool enabled) => _change(() async {
    if (enabled && _audioStream == null) {
      _audioStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
    } else if (!enabled) {
      await _stopStream(_audioStream);
      _audioStream = null;
    }
    microphoneEnabled = _audioStream != null;
  });
  Future<void> setCamera(bool enabled) => _change(() async {
    if (enabled && _cameraStream == null) {
      _cameraStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'width': 640, 'height': 360, 'frameRate': 15},
      });
    } else if (!enabled) {
      await _stopStream(_cameraStream);
      _cameraStream = null;
    }
    cameraEnabled = _cameraStream != null;
  });
  Future<void> setSharing(bool enabled) => _change(() async {
    if (enabled && _screenStream == null) {
      _screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
      _screenStream!.getVideoTracks().first.onEnded = () {
        unawaited(setSharing(false));
      };
    } else if (!enabled) {
      await _stopStream(_screenStream);
      _screenStream = null;
    }
    sharing = _screenStream != null;
  });

  Widget videoFor(String sessionId) {
    final renderer = sessionId == localSessionId
        ? _local
        : _peers[sessionId]?.renderer;
    final participant = participants
        .where((p) => p['session_id'] == sessionId)
        .firstOrNull;
    final visible =
        participant?['video'] == true || participant?['sharing'] == true;
    // Keep remote renderers mounted even for audio-only calls.
    return Stack(
      fit: StackFit.expand,
      children: [
        if (renderer != null && renderer.srcObject != null)
          RTCVideoView(
            renderer,
            mirror: sessionId == localSessionId && !sharing,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          ),
        if (!visible || renderer?.srcObject == null)
          const ColoredBox(
            color: Color(0xff263247),
            child: Center(
              child: Icon(Icons.person, size: 56, color: Colors.white70),
            ),
          ),
      ],
    );
  }

  Future<void> _stopStream(MediaStream? stream) async {
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      track.onEnded = null;
      await track.stop();
    }
    await stream.dispose();
  }

  Future<void> _stopCapture() async {
    await _stopStream(_audioStream);
    _audioStream = null;
    await _stopStream(_cameraStream);
    _cameraStream = null;
    await _stopStream(_screenStream);
    _screenStream = null;
    microphoneEnabled = cameraEnabled = sharing = false;
    if (_initialized) _local.srcObject = null;
  }

  Future<void> _closePeer(_Peer peer) async {
    peer.connection.onTrack = null;
    peer.connection.onIceCandidate = null;
    peer.connection.onConnectionState = null;
    await peer.connection.close();
    await peer.connection.dispose();
    peer.renderer.srcObject = null;
    await peer.renderer.dispose();
    await peer.received?.dispose();
  }

  Future<void> leave() async {
    _epoch++;
    _heartbeat?.cancel();
    _heartbeat = null;
    final session = localSessionId, office = _office, meeting = activeMeeting;
    localSessionId = null;
    activeMeeting = null;
    participants = [];
    await _stopCapture();
    final peers = _peers.values.toList();
    _peers.clear();
    for (final peer in peers) {
      await _closePeer(peer);
    }
    if (session != null && office != null && meeting != null) {
      try {
        await office.officeRequest(
          '/meetings/${meeting['id']}/leave',
          method: 'POST',
          data: {'session_id': session},
        );
      } catch (_) {
        /* TTL also expires abandoned sessions. */
      }
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(
      leave().whenComplete(() async {
        if (_initialized) await _local.dispose();
      }),
    );
    super.dispose();
  }
}
