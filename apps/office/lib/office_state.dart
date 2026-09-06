import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

typedef Json = Map<String, dynamic>;

class OfficeException implements Exception {
  final int status;
  final String message;
  OfficeException(this.status, this.message);
  @override
  String toString() => message;
}

/// Humans and agents use this same authenticated office protocol.
/// Credentials live in memory, never in compiled assets or browser storage.
class OfficeState extends ChangeNotifier {
  OfficeState({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  String endpoint = '';
  String _token = '';
  Json? me;
  List<Json> rooms = [],
      principals = [],
      agents = [],
      catalog = [],
      searchResults = [];
  List<Json> allDocuments = [], allTasks = [];
  List<Json> meetings = [], calendarEvents = [], apps = [];
  List<String> appFavorites = [];
  Json? detail;
  String? selectedRoomId;
  bool loading = false, connected = false;
  String error = '';
  int _generation = 0, _cursor = 0, _selection = 0, _search = 0;
  bool _disposed = false;
  final Map<String, int> _reads = {};
  final Map<String, String> _outbox = {};

  static String newClientId() {
    final random = Random.secure();
    return 'flutter-${DateTime.now().microsecondsSinceEpoch}-${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  List<Json> _list(dynamic value) => value is List
      ? value.whereType<Map>().map((e) => Json.from(e)).toList()
      : [];

  Future<dynamic> _request(
    String path, {
    String method = 'GET',
    Json? data,
    bool text = false,
    bool binary = false,
  }) async {
    if (_token.isEmpty) throw OfficeException(401, '请先登录工作身份');
    final request = http.Request(method, Uri.parse('$endpoint/api/im$path'));
    request.followRedirects = false;
    request.headers.addAll({
      'authorization': 'Bearer $_token',
      'content-type': 'application/json',
      'accept': text ? 'text/markdown' : 'application/json',
    });
    if (data != null) request.body = jsonEncode(data);
    try {
      final response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 35)),
      ).timeout(const Duration(seconds: 35));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final status = response.statusCode;
        throw OfficeException(
          status,
          status == 401
              ? '身份凭据已失效，请重新登录'
              : status == 403
              ? '你没有当前会话的操作权限'
              : status == 409
              ? '共同版本已变化。你的草稿仍在，请读取最新版本后合并'
              : status == 503
              ? '服务暂不可用，操作尚未确认，请稍后重试'
              : '操作未完成（$status），请检查输入后重试',
        );
      }
      if (binary) return response.bodyBytes;
      if (text) return response.body;
      final parsed = jsonDecode(response.body);
      if (parsed is! Map) throw OfficeException(502, '服务返回格式不正确');
      return Json.from(parsed);
    } on OfficeException {
      rethrow;
    } on TimeoutException {
      throw OfficeException(503, '连接超时。请检查服务地址；未发送的内容会保留');
    } on http.ClientException {
      throw OfficeException(503, '暂时无法连接办公服务，请检查网络与服务地址');
    } on FormatException {
      throw OfficeException(502, '服务返回格式不正确');
    }
  }

  Future<void> connect(String server, String token) async {
    var address = server.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw OfficeException(422, '请输入完整的 HTTP 或 HTTPS 办公服务地址');
    }
    if (token.trim().isEmpty) throw OfficeException(422, '请输入自己的身份令牌');
    _generation++;
    final generation = _generation;
    endpoint = address;
    _token = token.trim();
    loading = true;
    error = '';
    _notify();
    try {
      final identity = await _request('/me');
      if (generation != _generation) return;
      me = Json.from(identity['principal']);
      await refresh();
      if (generation != _generation) return;
      connected = true;
      if (rooms.isNotEmpty) await selectRoom(rooms.first['id'] as String);
      unawaited(_poll(generation));
    } catch (e) {
      if (generation == _generation) {
        me = null;
        _token = '';
        connected = false;
        error = e.toString();
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void disconnect() {
    _generation++;
    _selection++;
    _search++;
    _token = '';
    me = null;
    connected = false;
    loading = false;
    error = '';
    rooms = [];
    principals = [];
    agents = [];
    catalog = [];
    searchResults = [];
    allDocuments = [];
    allTasks = [];
    meetings = [];
    calendarEvents = [];
    apps = [];
    appFavorites = [];
    detail = null;
    selectedRoomId = null;
    _cursor = 0;
    _reads.clear();
    _outbox.clear();
    _notify();
  }

  Future<void> refresh() async {
    final generation = _generation;
    final results = await Future.wait([
      _request('/rooms'),
      _request('/principals'),
      _request('/agents'),
      _request('/agent-store'),
      _request('/library'),
      _request('/meetings'),
      _request('/calendar'),
      _request('/workbench'),
    ]);
    if (generation != _generation) return;
    rooms = _list(results[0]['rooms']);
    principals = _list(results[1]['principals']);
    agents = _list(results[2]['agents']);
    catalog = _list(results[3]['agents']);
    allDocuments = _list(results[4]['documents']);
    allTasks = _list(results[4]['tasks']);
    meetings = _list(results[5]['meetings']);
    calendarEvents = _list(results[6]['events']);
    apps = _list(results[7]['apps']);
    appFavorites = List<String>.from(results[7]['favorites'] ?? []);
    if (_cursor == 0) _cursor = (results[0]['cursor'] as num?)?.toInt() ?? 0;
    if (selectedRoomId != null &&
        !rooms.any((r) => r['id'] == selectedRoomId)) {
      selectedRoomId = null;
      detail = null;
      _selection++;
    }
    _notify();
  }

  Future<void> selectRoom(String id) async {
    final selection = ++_selection, generation = _generation;
    selectedRoomId = id;
    detail = null;
    error = '';
    _notify();
    final result = await _request('/rooms/${Uri.encodeComponent(id)}');
    if (selection != _selection || generation != _generation) return;
    detail = Json.from(result);
    _notify();
    await _markRead(id, result);
  }

  Future<void> _loadCurrent() async {
    final id = selectedRoomId, selection = _selection, generation = _generation;
    if (id == null) return;
    final result = await _request('/rooms/${Uri.encodeComponent(id)}');
    if (selection != _selection ||
        generation != _generation ||
        selectedRoomId != id) {
      return;
    }
    final previous = _list(detail?['messages']);
    final newest = _list(result['messages']);
    if (previous.length > 200 && newest.isNotEmpty) {
      var before = (newest.first['seq'] as num).toInt();
      final first = (previous.first['seq'] as num).toInt();
      while (before > first) {
        final page = await _request(
          '/rooms/${Uri.encodeComponent(id)}/messages?before=$before&limit=200',
        );
        if (selection != _selection || generation != _generation) return;
        final earlier = _list(page['messages']);
        if (earlier.isEmpty) break;
        newest.insertAll(0, earlier);
        before = (earlier.first['seq'] as num).toInt();
        result['has_more_messages'] = page['has_more'] == true;
        if (page['has_more'] != true) break;
      }
      result['messages'] = newest;
    }
    detail = Json.from(result);
    _notify();
    await _markRead(id, result);
  }

  Future<void> loadEarlierMessages() async {
    final id = selectedRoomId, selection = _selection, generation = _generation;
    if (id == null || detail == null) return;
    final current = _list(detail!['messages']);
    if (current.isEmpty || detail!['has_more_messages'] != true) return;
    final before = current.map((m) => (m['seq'] as num).toInt()).reduce(min);
    final page = await _request(
      '/rooms/${Uri.encodeComponent(id)}/messages?before=$before&limit=200',
    );
    if (selection != _selection ||
        generation != _generation ||
        detail == null) {
      return;
    }
    final merged = <String, Json>{};
    for (final message in [
      ..._list(page['messages']),
      ..._list(detail!['messages']),
    ]) {
      merged[message['id'] as String] = message;
    }
    detail!['messages'] = merged.values.toList()
      ..sort((a, b) => (a['seq'] as num).compareTo(b['seq'] as num));
    detail!['has_more_messages'] = page['has_more'] == true;
    _notify();
  }

  Future<void> _markRead(String id, Json room) async {
    final messages = _list(room['messages']);
    final sequence = messages.fold<int>(
      0,
      (maxValue, item) => max(maxValue, (item['seq'] as num?)?.toInt() ?? 0),
    );
    if (sequence <= (_reads[id] ?? 0)) return;
    await _request(
      '/rooms/$id/preferences',
      method: 'PATCH',
      data: {'read_seq': sequence},
    );
    _reads[id] = sequence;
    for (final room in rooms) {
      if (room['id'] == id) {
        room['unread_count'] = 0;
        room['read_seq'] = sequence;
      }
    }
    _notify();
  }

  Future<void> _poll(int generation) async {
    while (!_disposed && generation == _generation && _token.isNotEmpty) {
      try {
        await _request('/presence', method: 'POST', data: {'status': 'online'});
        final eventPage = await _request('/events?after=$_cursor&wait=20');
        if (generation != _generation) return;
        _cursor = (eventPage['cursor'] as num).toInt();
        connected = true;
        error = '';
        if (_list(eventPage['events']).isNotEmpty ||
            eventPage['reset_required'] == true) {
          await refresh();
          await _loadCurrent();
        }
        _notify();
      } catch (e) {
        if (generation != _generation || _disposed) return;
        connected = false;
        error = e.toString();
        _notify();
        if (e is OfficeException && e.status == 401) {
          disconnect();
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  String _room([String suffix = '']) {
    if (selectedRoomId == null) throw OfficeException(422, '请先选择一个会话');
    return '/rooms/${Uri.encodeComponent(selectedRoomId!)}$suffix';
  }

  Future<void> _updated() async {
    // The preceding mutation already succeeded. A refresh failure must never
    // make the UI resend that successful operation as a new intent.
    try {
      await refresh();
      await _loadCurrent();
    } catch (e) {
      connected = false;
      error = e.toString();
      _notify();
    }
  }

  Future<Json> createRoom(
    String name, {
    String description = '',
    List<String> memberIds = const [],
  }) async {
    final result = await _request(
      '/rooms',
      method: 'POST',
      data: {'name': name, 'description': description},
    );
    final room = Json.from(result['room']);
    for (final id in memberIds.toSet()) {
      if (id != me?['id']) {
        await _request(
          '/rooms/${room['id']}/members',
          method: 'POST',
          data: {'principal_id': id},
        );
      }
    }
    await refresh();
    await selectRoom(room['id']);
    return room;
  }

  Future<void> openDirect(String principalId) async {
    final result = await _request(
      '/rooms/direct',
      method: 'POST',
      data: {'principal_id': principalId},
    );
    await refresh();
    await selectRoom(result['room']['id']);
  }

  Future<void> search(String query) async {
    final generation = _generation, search = ++_search;
    if (query.trim().isEmpty) {
      searchResults = [];
      _notify();
      return;
    }
    final result = await _request(
      '/search?q=${Uri.encodeQueryComponent(query.trim())}',
    );
    if (generation == _generation && search == _search) {
      searchResults = _list(result['results']);
      _notify();
    }
  }

  Future<Json> send(
    String content, {
    List<String> mentions = const [],
    String? replyTo,
    String? clientId,
    List<String> attachmentIds = const [],
  }) async {
    final route = _room('/messages');
    final intent = jsonEncode([
      route,
      content,
      mentions,
      replyTo,
      attachmentIds,
    ]);
    final key = clientId ?? _outbox.putIfAbsent(intent, newClientId);
    final result = await _request(
      route,
      method: 'POST',
      data: {
        'client_id': key,
        'content': content,
        'mentions': mentions,
        'reply_to': ?replyTo,
        'attachment_ids': attachmentIds,
      },
    );
    _outbox.remove(intent);
    await _updated();
    return Json.from(result['message']);
  }

  Future<void> setPreferences({
    bool? favorite,
    bool? muted,
    int? readSeq,
  }) async {
    await _request(
      _room('/preferences'),
      method: 'PATCH',
      data: {'favorite': ?favorite, 'muted': ?muted, 'read_seq': ?readSeq},
    );
    await _updated();
  }

  Future<void> editMessage(Json message, String content) async {
    await _request(
      _room('/messages/${message['id']}'),
      method: 'PATCH',
      data: {'content': content, 'base_revision': message['revision'] ?? 1},
    );
    await _updated();
  }

  Future<void> retractMessage(Json message) async {
    await _request(
      _room('/messages/${message['id']}'),
      method: 'DELETE',
      data: {'base_revision': message['revision'] ?? 1},
    );
    await _updated();
  }

  Future<void> react(String messageId, String emoji) async {
    await _request(
      _room('/messages/$messageId/reactions'),
      method: 'POST',
      data: {'emoji': emoji},
    );
    await _updated();
  }

  Future<void> createTask(
    String title, {
    String description = '',
    String? assigneeId,
  }) async {
    await _request(
      _room('/tasks'),
      method: 'POST',
      data: {
        'title': title,
        'description': description,
        'assignee_id': assigneeId,
      },
    );
    await _updated();
  }

  Future<void> updateTask(
    Json task, {
    String? status,
    String? assigneeId,
  }) async {
    await _request(
      _room('/tasks/${task['id']}'),
      method: 'PATCH',
      data: {
        'base_revision': task['revision'],
        'status': ?status,
        'assignee_id': ?assigneeId,
      },
    );
    await _updated();
  }

  Future<Json> saveDocument({
    String? id,
    required String title,
    required String content,
    int? baseRevision,
  }) async {
    final result = await _request(
      _room('/documents${id == null ? '' : '/$id'}'),
      method: id == null ? 'POST' : 'PUT',
      data: {
        'title': title,
        'content': content,
        if (id != null) 'base_revision': baseRevision,
      },
    );
    await _updated();
    return Json.from(result['document']);
  }

  Future<Json> getRun(String id) async =>
      Json.from((await _request(_room('/turns/$id')))['turn']);
  Future<Json> saveArtifact(String runId) async {
    final run = await getRun(runId);
    final artifact = run['result']?['artifact'];
    if (artifact is! Map) throw OfficeException(422, '本轮没有文档成果');
    return saveDocument(title: artifact['title'], content: artifact['content']);
  }

  Future<void> invite(String principalId) async {
    await _request(
      _room('/members'),
      method: 'POST',
      data: {'principal_id': principalId},
    );
    await _updated();
  }

  Future<void> setParticipation(String principalId, String mode) async {
    await _request(
      _room('/participation'),
      method: 'PATCH',
      data: {'principal_id': principalId, 'mode': mode},
    );
    await _updated();
  }

  Future<Json> installAgent(String templateId) async {
    final result = await _request(
      '/agent-store/${Uri.encodeComponent(templateId)}/install',
      method: 'POST',
      data: {},
    );
    await _updated();
    return Json.from(result['principal']);
  }

  Future<void> addAgent(String principalId) async {
    await _request(
      '/agents',
      method: 'POST',
      data: {'principal_id': principalId},
    );
    await _updated();
  }

  Future<void> pinMessage(Json message, bool pinned) async {
    await _request(
      _room('/messages/${message['id']}/pin'),
      method: 'POST',
      data: {'pinned': pinned},
    );
    await _updated();
  }

  Future<Json> forwardMessage(Json message, String targetRoomId) =>
      _createOfficeItem(_room('/messages/${message['id']}/forward'), {
        'target_room_id': targetRoomId,
        'base_revision': message['revision'],
      }, 'message');

  Future<Json> uploadAttachment(
    String filename,
    Uint8List bytes, {
    String mimeType = 'application/octet-stream',
  }) {
    if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) {
      throw OfficeException(422, '文件大小需为 1 字节至 12 MB');
    }
    return _createOfficeItem(_room('/attachments'), {
      'filename': filename,
      'mime_type': mimeType,
      'data_base64': base64Encode(bytes),
    }, 'attachment');
  }

  Future<Uint8List> getAttachmentBytes(Json attachment) async {
    final room = attachment['room_id'] ?? selectedRoomId;
    if (room == null) throw OfficeException(422, '请先选择文件所属会话');
    return await _request(
      '/rooms/${Uri.encodeComponent(room)}/attachments/${Uri.encodeComponent(attachment['id'])}/content',
      binary: true,
    ) as Uint8List;
  }

  Future<void> deleteAttachment(Json attachment) async {
    final room = attachment['room_id'] ?? selectedRoomId;
    await _request(
      '/rooms/${Uri.encodeComponent(room)}/attachments/${Uri.encodeComponent(attachment['id'])}',
      method: 'DELETE',
      data: {},
    );
    await _updated();
  }

  /// Member-authenticated transport used by native media signaling as well as UI.
  /// No actor headers, admin credentials, redirects or persistence of SDP/ICE.
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async => Json.from(await _request(path, method: method, data: data));

  Future<void> refreshOffice() async {
    final generation = _generation;
    final results = await Future.wait([
      _request('/meetings'),
      _request('/calendar'),
      _request('/workbench'),
    ]);
    if (generation != _generation) return;
    meetings = _list(results[0]['meetings']);
    calendarEvents = _list(results[1]['events']);
    apps = _list(results[2]['apps']);
    appFavorites = List<String>.from(results[2]['favorites'] ?? []);
    _notify();
  }

  Future<Json> _createOfficeItem(String route, Json body, String key) async {
    final intent = jsonEncode([route, body]);
    final clientId = _outbox.putIfAbsent(intent, newClientId);
    final result = await _request(
      route,
      method: 'POST',
      data: {...body, 'client_id': clientId},
    );
    _outbox.remove(intent);
    await _updated();
    return Json.from(result[key]);
  }

  Future<Json> createMeeting({
    required String title,
    String? startsAt,
    int durationMinutes = 30,
    String? documentId,
  }) => _createOfficeItem(_room('/meetings'), {
    'title': title,
    'starts_at': ?startsAt,
    'duration_minutes': durationMinutes,
    'document_id': ?documentId,
  }, 'meeting');

  Future<Json> meetingDetail(String id) =>
      officeRequest('/meetings/${Uri.encodeComponent(id)}');
  Future<void> endMeeting(String id) async {
    await _request(
      '/meetings/${Uri.encodeComponent(id)}/end',
      method: 'POST',
      data: {},
    );
    await _updated();
  }

  Future<void> bindMeetingNotes(Json meeting, String documentId) async {
    await _request(
      '/meetings/${meeting['id']}',
      method: 'PATCH',
      data: {'base_revision': meeting['revision'], 'document_id': documentId},
    );
    await _updated();
  }

  Future<Json> createCalendarEvent({
    required String title,
    required String startsAt,
    required String endsAt,
    String description = '',
    String location = '',
    List<String> attendeeIds = const [],
  }) => _createOfficeItem(_room('/calendar'), {
    'title': title,
    'starts_at': startsAt,
    'ends_at': endsAt,
    'description': description,
    'location': location,
    'attendee_ids': attendeeIds,
  }, 'event');
  Future<void> updateCalendarEvent(Json event, Json changes) async {
    await _request(
      '/calendar/${event['id']}',
      method: 'PATCH',
      data: {...changes, 'base_revision': event['revision']},
    );
    await _updated();
  }

  Future<void> respondCalendarEvent(String id, String response) async {
    await _request(
      '/calendar/${Uri.encodeComponent(id)}/respond',
      method: 'POST',
      data: {'response': response},
    );
    await _updated();
  }

  Future<void> setAppFavorites(List<String> favorites) async {
    await _request(
      '/workbench',
      method: 'PATCH',
      data: {'favorites': favorites},
    );
    await _updated();
  }

  Future<String> exportRoom() async =>
      await _request(_room('/export'), text: true) as String;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _client.close();
    super.dispose();
  }
}
