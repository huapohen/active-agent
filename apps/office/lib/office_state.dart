import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

typedef Json = Map<String, dynamic>;

class OfficeExternalLogin {
  const OfficeExternalLogin({
    required this.providerId,
    required this.authorizationUrl,
    required this.verifier,
    required this.expiresIn,
  });
  final String providerId, authorizationUrl, verifier;
  final int expiresIn;
}

class OfficeException implements Exception {
  final int status;
  final String message;
  final String? code, pluginId;
  OfficeException(this.status, this.message, {this.code, this.pluginId});
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
  String? _loginSessionId;
  Json? me;
  List<Json> rooms = [],
      principals = [],
      agents = [],
      catalog = [],
      searchResults = [];
  List<Json> allDocuments = [], allTasks = [], libraryRooms = [];
  List<Json> meetings = [], calendarEvents = [], apps = [];
  List<String> appFavorites = [];
  Json settings = {}, accountInfo = {}, currentAttendance = {};
  Json enterpriseSummary = {};
  bool get canManageEnterprise =>
      (enterpriseSummary['capabilities'] as Map?)?['access_admin'] == true;
  List<Json> contacts = [], plugins = [], capabilities = [];
  List<Json> attendanceRecords = [],
      approvalTemplates = [],
      approvalRequests = [],
      mailFolders = [],
      mailItems = [],
      accountSessions = [];
  final Set<String> unavailableModules = {};
  bool moduleAvailable(String id) => !unavailableModules.contains(id);
  String mailFolder = 'inbox';
  String _mailQuery = '';
  Json? detail;
  String? selectedRoomId;
  bool loading = false, connected = false;
  bool searchTruncated = false;
  Json searchFilters = {};
  String error = '';
  int _generation = 0, _cursor = 0, _selection = 0, _search = 0;
  bool _disposed = false;
  final Map<String, int> _reads = {};
  final Map<String, ({int sequence, int visibility, int generation})> _reading =
      {};
  String? _visibleConversationRoomId;
  int _conversationVisibilityVersion = 0;
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
    final generation = _generation;
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
        String? known, code, pluginId;
        try {
          final body = jsonDecode(response.body);
          if (body is Map) {
            final nested = body['error'];
            final value =
                body['code'] ?? (nested is Map ? nested['code'] : null);
            code = value is String ? value : null;
            pluginId = body['plugin_id'] is String ? body['plugin_id'] : null;
          }
          known = const {
            'app_policy_denied': '企业管理员已限制此应用，请查看企业应用范围',
            'enterprise_admin_required': '当前身份没有企业管理权限',
            'enterprise_owner_required': '此操作需要企业所有者权限',
            'last_enterprise_owner': '必须保留至少一位有效企业所有者',
            'already_checked_in': '今天已经打过上班卡',
            'already_checked_out': '今天已经打过下班卡',
            'check_in_required': '请先打上班卡',
            'attendance_conflict': '考勤记录已变化，请核对后重新申请补卡',
            'meeting_ended': '会议已结束',
            'meeting_full': '这场会议已达到人数上限',
            'session_expired': '会议连接已失效，请重新加入',
            'attachment_unavailable': '文件已被删除或其消息已撤回',
            'already_sent': '这封邮件已经发送',
            'incomplete_mail': '请选择收件人并填写主题',
            'invalid_credentials': '账号或密码不正确',
          }[code];
        } catch (_) {
          /* Only known stable codes are displayed. */
        }
        if (status == 403 &&
            code == 'app_policy_denied' &&
            pluginId != null &&
            generation == _generation) {
          _denyModule(pluginId);
        }
        throw OfficeException(
          status,
          known ??
              (status == 401
                  ? '身份凭据已失效，请重新登录'
                  : status == 403
                  ? '你没有当前会话的操作权限'
                  : status == 409
                  ? '共同版本已变化。你的草稿仍在，请读取最新版本后合并'
                  : status == 503
                  ? '服务暂不可用，操作尚未确认，请稍后重试'
                  : '操作未完成（$status），请检查输入后重试'),
          code: code,
          pluginId: pluginId,
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

  void _denyModule(String id) {
    unavailableModules.add(id);
    searchResults = [];
    searchTruncated = false;
    searchFilters = {};
    switch (id) {
      case 'im':
        _clearConversationVisibility();
        rooms = [];
        principals = [];
        agents = [];
        catalog = [];
        contacts = [];
        detail = null;
        selectedRoomId = null;
        _selection++;
      case 'docs':
        allDocuments = [];
        detail?['documents'] = [];
      case 'tasks':
        allTasks = [];
        detail?['tasks'] = [];
      case 'meetings':
        meetings = [];
      case 'calendar':
        calendarEvents = [];
      case 'attendance':
        attendanceRecords = [];
        currentAttendance = {};
      case 'approvals':
        approvalTemplates = [];
        approvalRequests = [];
      case 'mail':
        mailItems = [];
        mailFolders = [];
      case 'workbench':
        apps = [];
        appFavorites = [];
    }
    if (['docs', 'tasks', 'meetings', 'calendar'].contains(id)) {
      detail?['runs'] = [];
    }
    _notify();
  }

  /// Policy-denied background modules must not prevent identity/settings access.
  /// Other permission errors, expired sessions and transport failures still surface.
  Future<dynamic> _backgroundRequest(
    String path, {
    String? plugin,
    String method = 'GET',
    Json? data,
  }) async {
    final generation = _generation;
    try {
      final result = await _request(path, method: method, data: data);
      if (generation == _generation && plugin != null) {
        unavailableModules.remove(plugin);
      }
      return result;
    } on OfficeException catch (e) {
      if (e.status != 403 || e.code != 'app_policy_denied') rethrow;
      if (generation == _generation && plugin != null) _denyModule(plugin);
      return <String, dynamic>{};
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
    disconnect();
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
      await refreshBusiness();
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
    if (_loginSessionId != null && _token.isNotEmpty) {
      unawaited(
        _request(
          '/auth/logout',
          method: 'POST',
          data: {},
        ).catchError((Object _) => <String, dynamic>{}),
      );
    }
    _loginSessionId = null;
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
    searchTruncated = false;
    searchFilters = {};
    allDocuments = [];
    allTasks = [];
    libraryRooms = [];
    meetings = [];
    calendarEvents = [];
    apps = [];
    appFavorites = [];
    settings = {};
    accountInfo = {};
    enterpriseSummary = {};
    currentAttendance = {};
    attendanceRecords = [];
    approvalTemplates = [];
    approvalRequests = [];
    mailFolders = [];
    mailItems = [];
    accountSessions = [];
    contacts = [];
    plugins = [];
    capabilities = [];
    _mailQuery = '';
    mailFolder = 'inbox';
    unavailableModules.clear();
    detail = null;
    selectedRoomId = null;
    _clearConversationVisibility();
    _cursor = 0;
    _reads.clear();
    _reading.clear();
    _outbox.clear();
    _notify();
  }

  Future<void> refresh() async {
    final generation = _generation;
    final results = await Future.wait([
      _backgroundRequest('/rooms', plugin: 'im'),
      _backgroundRequest('/principals', plugin: 'im'),
      _backgroundRequest('/agents', plugin: 'im'),
      _backgroundRequest('/agent-store', plugin: 'im'),
      _request('/library'),
      _backgroundRequest('/meetings', plugin: 'meetings'),
      _backgroundRequest('/calendar', plugin: 'calendar'),
      _backgroundRequest('/workbench', plugin: 'workbench'),
    ]);
    if (generation != _generation) return;
    rooms = _list(results[0]['rooms']);
    principals = _list(results[1]['principals']);
    agents = _list(results[2]['agents']);
    catalog = _list(results[3]['agents']);
    allDocuments = _list(results[4]['documents']);
    allTasks = _list(results[4]['tasks']);
    libraryRooms = _list(results[4]['rooms']);
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
    if (_visibleConversationRoomId != id) _clearConversationVisibility();
    final selection = ++_selection, generation = _generation;
    selectedRoomId = id;
    _selectAttendance();
    detail = null;
    error = '';
    _notify();
    final result = await _backgroundRequest(
      '/rooms/${Uri.encodeComponent(id)}',
      plugin: 'im',
    );
    if (selection != _selection || generation != _generation) return;
    detail = Json.from(result);
    _notify();
    await _markRead(id, result);
  }

  Future<void> _loadCurrent() async {
    final id = selectedRoomId, selection = _selection, generation = _generation;
    if (id == null) return;
    final result = await _backgroundRequest(
      '/rooms/${Uri.encodeComponent(id)}',
      plugin: 'im',
    );
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

  void _clearConversationVisibility() {
    _visibleConversationRoomId = null;
    _conversationVisibilityVersion++;
  }

  /// The client calls this only for the conversation actually shown while the
  /// application is foregrounded. Loading or selecting a room is not a receipt.
  /// A stale widget may hide its own room without hiding a newer visible room.
  Future<void> setConversationVisible(String roomId, bool visible) async {
    if (_disposed) return;
    if (!visible) {
      if (_visibleConversationRoomId == roomId) _clearConversationVisibility();
      return;
    }
    if (selectedRoomId != roomId || me == null || _token.isEmpty) return;
    if (_visibleConversationRoomId != roomId) {
      _visibleConversationRoomId = roomId;
      _conversationVisibilityVersion++;
    }
    final current = detail;
    if (current != null) await _markRead(roomId, current);
  }

  Future<void> _markRead(String id, Json room) async {
    if (_disposed || _visibleConversationRoomId != id || selectedRoomId != id) {
      return;
    }
    final generation = _generation, visibility = _conversationVisibilityVersion;
    final messages = _list(room['messages']);
    final sequence = messages.fold<int>(
      0,
      (maxValue, item) => max(maxValue, (item['seq'] as num?)?.toInt() ?? 0),
    );
    final pending = _reading[id];
    final pendingSequence =
        pending?.visibility == visibility && pending?.generation == generation
        ? pending!.sequence
        : 0;
    if (sequence <= max(_reads[id] ?? 0, pendingSequence)) return;
    final receipt = (
      sequence: sequence,
      visibility: visibility,
      generation: generation,
    );
    _reading[id] = receipt;
    try {
      await _request(
        '/rooms/${Uri.encodeComponent(id)}/preferences',
        method: 'PATCH',
        data: {'read_seq': sequence},
      );
    } finally {
      if (_reading[id] == receipt) {
        _reading.remove(id);
      }
    }
    // A receipt already sent cannot be undone. Its delayed response must not
    // alter another identity, a hidden room, or newer unread state.
    if (_disposed ||
        generation != _generation ||
        visibility != _conversationVisibilityVersion ||
        _visibleConversationRoomId != id ||
        selectedRoomId != id) {
      return;
    }
    _reads[id] = max(sequence, _reads[id] ?? 0);
    for (final room in rooms) {
      if (room['id'] == id) {
        final acknowledged = max(
          _reads[id]!,
          (room['read_seq'] as num?)?.toInt() ?? 0,
        );
        final latest = max(
          ((room['last_message'] as Map?)?['seq'] as num?)?.toInt() ?? 0,
          _list(detail?['messages']).fold<int>(
            0,
            (value, message) =>
                max(value, (message['seq'] as num?)?.toInt() ?? 0),
          ),
        );
        if (latest <= acknowledged) room['unread_count'] = 0;
        room['read_seq'] = acknowledged;
      }
    }
    _notify();
  }

  Future<void> _poll(int generation) async {
    while (!_disposed && generation == _generation && _token.isNotEmpty) {
      try {
        await _backgroundRequest(
          '/presence',
          plugin: 'im',
          method: 'POST',
          data: {'status': 'online'},
        );
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
        await refreshBusiness();
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
      await refreshBusiness();
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

  Future<void> search(
    String query, {
    String type = 'all',
    String? roomId,
    String? authorId,
    String? after,
    String? before,
  }) async {
    final generation = _generation, search = ++_search;
    if (query.trim().isEmpty) {
      searchResults = [];
      searchTruncated = false;
      searchFilters = {};
      _notify();
      return;
    }
    final encoded = Uri(
      queryParameters: {
        'q': query.trim(),
        if (type != 'all') 'type': type,
        'room_id': ?roomId,
        'author_id': ?authorId,
        'after': ?after,
        'before': ?before,
      },
    ).query;
    final result = await _request('/search?$encoded');
    if (generation == _generation && search == _search) {
      searchResults = _list(result['results']);
      searchTruncated = result['truncated'] == true;
      searchFilters = Json.from(result['filters'] ?? {});
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

  Future<void> editMessage(
    Json message,
    String content, {
    String? sourceRoomId,
  }) async {
    await _request(
      sourceRoomId == null
          ? _room('/messages/${message['id']}')
          : '/rooms/${Uri.encodeComponent(sourceRoomId)}/messages/${message['id']}',
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
    String? roomId,
  }) async {
    await _request(
      _businessRoom(roomId, '/tasks'),
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
    String? roomId,
  }) async {
    await _request(
      _businessRoom(
        roomId ?? task['room_id'],
        '/tasks/${Uri.encodeComponent(task['id'])}',
      ),
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
    String? roomId,
  }) async {
    final result = await _request(
      _businessRoom(
        roomId,
        '/documents${id == null ? '' : '/${Uri.encodeComponent(id)}'}',
      ),
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

  String _businessRoom(String? roomId, String suffix) {
    if (roomId == null) return _room(suffix);
    return '/rooms/${Uri.encodeComponent(roomId)}$suffix';
  }

  Future<Json> getDocument(String id, {required String roomId}) async =>
      Json.from(
        (await _request(
          _businessRoom(roomId, '/documents/${Uri.encodeComponent(id)}'),
        ))['document'],
      );

  Future<Uri> documentEditorUrl(String id, {required String roomId}) async {
    final result = await _request(
      _businessRoom(
        roomId,
        '/documents/${Uri.encodeComponent(id)}/editor-session',
      ),
      method: 'POST',
      data: {},
    );
    final value = result['path'];
    if (value is! String || !value.startsWith('/office-document#open=')) {
      throw const FormatException('无效协作编辑器入口');
    }
    return Uri.parse(endpoint).resolve(value);
  }

  Future<Json> getRun(String id) async {
    final route = _room('/turns/${Uri.encodeComponent(id)}');
    final run = Json.from((await _request(route))['turn']);
    if (run['action_plan'] is Map) {
      final result = await _request('$route/plan');
      if (result['plan'] is Map) run['action_plan'] = Json.from(result['plan']);
      run['action_receipts'] = _list(result['receipts']);
    }
    return run;
  }

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

  Future<Json> configureAgentAutonomy(
    String roomId,
    String principalId, {
    required int baseRevision,
    required Json autonomy,
  }) async {
    final result = await officeRequest(
      '/rooms/${Uri.encodeComponent(roomId)}/participation',
      method: 'PATCH',
      data: {
        'principal_id': principalId,
        'base_revision': baseRevision,
        'autonomy': autonomy,
      },
    );
    _applyAgentMemberResult(roomId, principalId, result);
    return result;
  }

  Future<Json> configureAgentParticipation(
    String roomId,
    String principalId, {
    required String mode,
    required int baseRevision,
  }) async {
    final result = await officeRequest(
      '/rooms/${Uri.encodeComponent(roomId)}/participation',
      method: 'PATCH',
      data: {
        'principal_id': principalId,
        'base_revision': baseRevision,
        'mode': mode,
      },
    );
    _applyAgentMemberResult(roomId, principalId, result);
    return result;
  }

  void _applyAgentMemberResult(String roomId, String principalId, Json result) {
    if (selectedRoomId == roomId && detail != null && result['member'] is Map) {
      final saved = Json.from(result['member']);
      detail!['members'] = _list(detail!['members'])
          .map(
            (member) => (member['principal_id'] ?? member['id']) == principalId
                ? {...member, ...saved}
                : member,
          )
          .toList();
      if (detail!['room'] is Map) {
        detail!['room']['revision'] = result['room_revision'];
      }
      _notify();
    }
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

  Future<void> loginWithPassword(
    String server,
    String username,
    String password,
  ) async {
    final address = server.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw OfficeException(422, '请输入完整的办公服务地址');
    }
    final request =
        http.Request('POST', Uri.parse('$address/api/im/auth/login'))
          ..followRedirects = false
          ..headers['content-type'] = 'application/json'
          ..body = jsonEncode({'username': username, 'password': password});
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 35)),
    );
    if (response.statusCode != 200) {
      throw OfficeException(
        response.statusCode,
        response.statusCode == 429 ? '尝试次数过多，请稍后重试' : '登录未完成，请检查账号、密码和服务地址',
      );
    }
    final result = Json.from(jsonDecode(response.body));
    await connect(address, result['token'] as String);
    _loginSessionId = result['session_id'] as String?;
  }

  Future<Json> _publicAuthRequest(
    String server,
    String path, {
    Json? data,
  }) async {
    final address = server.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw OfficeException(422, '请输入完整的办公服务地址');
    }
    final request =
        http.Request(
            data == null ? 'GET' : 'POST',
            Uri.parse('$address/api/im$path'),
          )
          ..followRedirects = false
          ..headers['content-type'] = 'application/json';
    if (data != null) request.body = jsonEncode(data);
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 15)),
    ).timeout(const Duration(seconds: 15));
    Json result;
    try {
      result = Json.from(jsonDecode(response.body));
    } catch (_) {
      throw OfficeException(response.statusCode, '登录服务返回了无法识别的响应');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = result['error'];
      final code = result['code'] ?? (error is Map ? error['code'] : error);
      throw OfficeException(
        response.statusCode,
        const {
              'external_identity_unbound': '该企业身份尚未绑定工作成员，请联系管理员',
              'auth_provider_disabled': '此企业登录方式已停用，请重新读取登录方式',
              'oidc_authorization_failed': '授权未完成或一次性登录码已失效，请重新发起登录',
              'login_rate_limited': '尝试次数过多，请稍后重试',
            }[code] ??
            '企业登录未完成，请重新发起登录',
        code: code is String ? code : null,
      );
    }
    return result;
  }

  Future<Json> discoverAuthProviders(String server) =>
      _publicAuthRequest(server, '/auth/providers');

  Future<OfficeExternalLogin> startExternalLogin(
    String server,
    String providerId,
  ) async {
    final random = Random.secure();
    final verifier = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final result = await _publicAuthRequest(
      server,
      '/auth/oidc/${Uri.encodeComponent(providerId)}/start',
      data: {'code_challenge': challenge},
    );
    final url = result['authorization_url'] as String?;
    final uri = Uri.tryParse(url ?? '');
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw OfficeException(422, '企业授权地址无效');
    }
    return OfficeExternalLogin(
      providerId: providerId,
      authorizationUrl: url!,
      verifier: verifier,
      expiresIn: (result['expires_in'] as num?)?.toInt() ?? 600,
    );
  }

  Future<void> exchangeExternalLogin(
    String server,
    OfficeExternalLogin attempt,
    String code,
  ) async {
    final result = await _publicAuthRequest(
      server,
      '/auth/oidc/${Uri.encodeComponent(attempt.providerId)}/exchange',
      data: {'code': code.trim(), 'code_verifier': attempt.verifier},
    );
    final token = result['token'];
    if (token is! String || token.isEmpty) {
      throw OfficeException(422, '企业登录响应缺少工作身份');
    }
    await connect(server, token);
    _loginSessionId = result['session_id'] as String?;
  }

  void _selectAttendance() {
    currentAttendance =
        attendanceRecords
            .where(
              (r) =>
                  r['room_id'] == selectedRoomId &&
                  r['principal_id'] == me?['id'],
            )
            .firstOrNull ??
        {};
  }

  Future<void> refreshBusiness() async {
    final generation = _generation;
    final results = await Future.wait([
      _backgroundRequest(
        '/attendance?timezone=Asia%2FShanghai',
        plugin: 'attendance',
      ),
      _backgroundRequest('/approval-templates', plugin: 'approvals'),
      _backgroundRequest('/approvals?inbox=all', plugin: 'approvals'),
      _backgroundRequest('/mail/folders', plugin: 'mail'),
      _request('/settings'),
      _request('/auth/account'),
      _backgroundRequest('/contacts', plugin: 'im'),
      _request('/enterprise'),
    ]);
    if (generation != _generation) return;
    attendanceRecords = _list(results[0]['records']);
    _selectAttendance();
    approvalTemplates = _list(results[1]['templates']);
    approvalRequests = _list(results[2]['requests']);
    mailFolders = _list(results[3]['folders']);
    settings = Json.from(results[4]['settings'] ?? {});
    accountInfo = Json.from(results[5]['account'] ?? {});
    contacts = _list(results[6]['contacts']);
    enterpriseSummary = Json.from(results[7]);
    await loadMail(mailFolder, query: _mailQuery);
    await loadPlugins();
    _notify();
  }

  Future<void> loadPlugins() async {
    final generation = _generation;
    final results = await Future.wait([
      _request('/plugins'),
      _request('/capabilities'),
    ]);
    if (generation != _generation) return;
    plugins = _list(results[0]['plugins']);
    capabilities = _list(results[1]['capabilities']);
    for (final plugin in plugins) {
      final id = plugin['id'];
      if (id is! String || plugin['enterprise_allowed'] is! bool) continue;
      if (plugin['enterprise_allowed'] == false) {
        _denyModule(id);
      } else {
        unavailableModules.remove(id);
      }
    }
    if (!moduleAvailable('docs') || !moduleAvailable('calendar')) {
      _denyModule('meetings');
    }
    _notify();
  }

  Future<void> configurePlugin(
    Json plugin, {
    bool? enabled,
    Json? config,
  }) async {
    await _request(
      '/plugins/${plugin['id']}',
      method: 'PATCH',
      data: {
        'base_revision': plugin['revision'],
        'enabled': ?enabled,
        'config': ?config,
      },
    );
    await loadPlugins();
  }

  Future<void> addContact(String principalId) async {
    await _request(
      '/contacts',
      method: 'POST',
      data: {'principal_id': principalId},
    );
    await _updated();
  }

  Future<void> getAccount() async {
    accountInfo = Json.from((await _request('/auth/account'))['account'] ?? {});
    _notify();
  }

  Future<void> setAccount(
    String username,
    String password, {
    String? currentPassword,
  }) async {
    await _request(
      '/auth/account',
      method: 'POST',
      data: {
        'username': username,
        'password': password,
        'current_password': ?currentPassword,
      },
    );
    // Password changes revoke browser sessions; reconnect with the new account.
    await loginWithPassword(endpoint, username, password);
  }

  Future<void> loadAccountSessions() async {
    accountSessions = _list((await _request('/auth/sessions'))['sessions']);
    _notify();
  }

  Future<void> revokeSession(String id) async {
    await _request(
      '/auth/sessions/${Uri.encodeComponent(id)}',
      method: 'DELETE',
      data: {},
    );
    if (id == _loginSessionId) {
      disconnect();
      return;
    }
    await loadAccountSessions();
  }

  Future<void> loadAttendance({String? date}) async {
    final result = await _request(
      '/attendance?timezone=Asia%2FShanghai${date == null ? '' : '&date=${Uri.encodeQueryComponent(date)}'}',
    );
    attendanceRecords = _list(result['records']);
    _selectAttendance();
    _notify();
  }

  Future<Json> checkIn({String locationNote = '', String? roomId}) =>
      _createOfficeItem(_businessRoom(roomId, '/attendance'), {
        'action': 'check_in',
        'timezone': 'Asia/Shanghai',
        'location_note': locationNote,
      }, 'record');
  Future<Json> checkOut({String locationNote = '', String? roomId}) =>
      _createOfficeItem(_businessRoom(roomId, '/attendance'), {
        'action': 'check_out',
        'timezone': 'Asia/Shanghai',
        'location_note': locationNote,
      }, 'record');
  Future<Json> createAttendanceCorrection({
    required String date,
    required String checkInAt,
    String? checkOutAt,
    required String reason,
    required String approverId,
    String? roomId,
  }) => _createOfficeItem(_businessRoom(roomId, '/attendance/corrections'), {
    'date': date,
    'timezone': 'Asia/Shanghai',
    'check_in_at': checkInAt,
    'check_out_at': ?checkOutAt,
    'reason': reason,
    'approver_id': approverId,
  }, 'request');
  Future<Json> createApproval({
    required String templateId,
    required String title,
    String description = '',
    required String approverId,
    Json fields = const {},
    String? roomId,
  }) => _createOfficeItem(_businessRoom(roomId, '/approvals'), {
    'template_id': templateId,
    'title': title,
    'description': description,
    'approver_id': approverId,
    'payload': fields,
  }, 'request');
  Future<Json> getApproval(String id) async => Json.from(
    (await _request('/approvals/${Uri.encodeComponent(id)}'))['request'],
  );
  Future<void> decideApproval(
    Json request,
    String decision, {
    String comment = '',
  }) async {
    await _createOfficeItem('/approvals/${request['id']}/decision', {
      'base_revision': request['revision'],
      'decision': decision,
      'comment': comment,
    }, 'request');
  }

  Future<void> withdrawApproval(Json request) async {
    await _createOfficeItem('/approvals/${request['id']}/cancel', {
      'base_revision': request['revision'],
    }, 'request');
  }

  Future<void> loadMail(String folder, {String query = ''}) async {
    final generation = _generation;
    mailFolder = folder;
    _mailQuery = query;
    final result = await _backgroundRequest(
      '/mail?folder=${Uri.encodeQueryComponent(folder)}&q=${Uri.encodeQueryComponent(query)}',
      plugin: 'mail',
    );
    if (generation != _generation || mailFolder != folder) return;
    mailItems = _list(result['items']);
    _notify();
  }

  Future<Json> getMail(String id) async =>
      Json.from((await _request('/mail/${Uri.encodeComponent(id)}'))['item']);
  Future<Json> saveMailDraft({
    String? id,
    int? baseRevision,
    List<String> toIds = const [],
    List<String> ccIds = const [],
    List<String> bccIds = const [],
    String subject = '',
    String body = '',
  }) async {
    final payload = {
      'to_ids': toIds,
      'cc_ids': ccIds,
      'bcc_ids': bccIds,
      'subject': subject,
      'body': body,
    };
    if (id == null) return _createOfficeItem('/mail/drafts', payload, 'draft');
    final result = await _request(
      '/mail/${Uri.encodeComponent(id)}',
      method: 'PATCH',
      data: {...payload, 'base_revision': baseRevision},
    );
    await _updated();
    return Json.from(result['draft']);
  }

  Future<Json> sendMailDraft(Json draft) => _createOfficeItem(
    '/mail/${draft['message_id'] ?? draft['id']}/send',
    {'base_revision': draft['draft_revision'] ?? draft['revision']},
    'item',
  );
  Future<void> moveMail(Json item, String folder) async {
    final discarding = item['status'] == 'draft' && folder == 'trash';
    await _request(
      '/mail/${item['id']}',
      method: discarding ? 'DELETE' : 'PATCH',
      data: {
        'base_revision': item['revision'],
        if (!discarding) 'folder': folder,
      },
    );
    await _updated();
  }

  Future<void> markMailRead(Json item, bool read) async {
    await _request(
      '/mail/${item['id']}',
      method: 'PATCH',
      data: {'base_revision': item['revision'], 'read': read},
    );
    await _updated();
  }

  Future<void> saveSettings(Json changes, {int? baseRevision}) async {
    final result = await _request(
      '/settings',
      method: 'PATCH',
      data: {
        ...changes,
        'base_revision': baseRevision ?? settings['revision'] ?? 1,
      },
    );
    settings = Json.from(result['settings']);
    _notify();
  }

  Future<void> pinMessage(Json message, bool pinned) async {
    await _request(
      _room('/messages/${message['id']}/pin'),
      method: 'POST',
      data: {'pinned': pinned},
    );
    await _updated();
  }

  Future<Json> forwardMessage(
    Json message,
    String targetRoomId, {
    String? sourceRoomId,
  }) => _createOfficeItem(
    sourceRoomId == null
        ? _room('/messages/${message['id']}/forward')
        : '/rooms/${Uri.encodeComponent(sourceRoomId)}/messages/${message['id']}/forward',
    {'target_room_id': targetRoomId, 'base_revision': message['revision']},
    'message',
  );

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

  Future<String> officeTextRequest(String path) async =>
      await _request(path, text: true) as String;

  Future<void> refreshOffice() async {
    final generation = _generation;
    final results = await Future.wait([
      _backgroundRequest('/meetings', plugin: 'meetings'),
      _backgroundRequest('/calendar', plugin: 'calendar'),
      _backgroundRequest('/workbench', plugin: 'workbench'),
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
    String? roomId,
  }) => _createOfficeItem(_businessRoom(roomId, '/meetings'), {
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
    String? roomId,
  }) => _createOfficeItem(_businessRoom(roomId, '/calendar'), {
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
    _clearConversationVisibility();
    _generation++;
    _client.close();
    super.dispose();
  }
}
