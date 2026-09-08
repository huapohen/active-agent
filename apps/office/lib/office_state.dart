import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import 'conversation_unread.dart';
import 'voice_audio.dart';
export 'conversation_unread.dart';

typedef Json = Map<String, dynamic>;
typedef OfficeVoiceRecorderFactory = OfficeVoiceRecorder Function(
  bool Function() isCurrent,
  Duration maxDuration,
);
typedef OfficeVoicePlaybackFactory = OfficeVoicePlayback Function(
  bool Function() isCurrent,
);

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
  OfficeState({
    http.Client? client,
    this.voiceRecorderFactory,
    this.voicePlaybackFactory,
  }) : _client = client ?? http.Client();
  final http.Client _client;
  final OfficeVoiceRecorderFactory? voiceRecorderFactory;
  final OfficeVoicePlaybackFactory? voicePlaybackFactory;
  OfficeVoiceRecorder createVoiceRecorder(
    bool Function() isCurrent, {
    Duration maxDuration = const Duration(seconds: 60),
  }) =>
      voiceRecorderFactory?.call(isCurrent, maxDuration) ??
      OfficeVoiceRecorder(isCurrent: isCurrent, maxDuration: maxDuration);
  OfficeVoicePlayback createVoicePlayback(bool Function() isCurrent) =>
      voicePlaybackFactory?.call(isCurrent) ??
      OfficeVoicePlayback(isCurrent: isCurrent);

  OfficeVoicePlayback? _voicePlayback;
  OfficeVoicePlayback get voicePlayback =>
      _voicePlayback ??= createVoicePlayback(() => _voiceScopeCurrent);
  ({int generation, String endpoint, String? principalId})? _voiceIdentity;
  String? _voiceRoomId, _voiceAttachmentId, _voiceError;
  int _voiceSelection = -1, _voiceOperation = 0;
  bool _voiceLoading = false;
  String? get voiceAttachmentId => _voiceAttachmentId;
  String? get voicePlaybackError => _voiceError;
  bool get voiceLoading => _voiceLoading;
  bool get _voiceScopeCurrent =>
      !_disposed &&
      _voiceIdentity == _identity &&
      _voiceRoomId == selectedRoomId &&
      _voiceSelection == _selection;
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
  // Masters remain separate from the bounded, server-expanded visible window.
  List<Json>? calendarOccurrences;
  List<Json> get calendarViewEvents => calendarOccurrences ?? calendarEvents;
  bool calendarOccurrencesLoading = false, calendarOccurrencesTruncated = false;
  String? calendarOccurrencesError, calendarNextCursor;
  ({String from, String to, String timezone})? _calendarWindow;
  int _calendarRead = 0;
  List<String> appFavorites = [], appRecents = [];
  Future<void> _workbenchQueue = Future<void>.value();
  int _workbenchPending = 0, _workbenchChange = 0, _workbenchRead = 0;
  Json settings = {}, accountInfo = {}, currentAttendance = {};
  Json enterpriseSummary = {};
  bool get canManageEnterprise {
    final capabilities = enterpriseSummary['capabilities'];
    final membership = enterpriseSummary['membership'];
    final status = membership is Map ? membership['status'] : null;
    // Capabilities are issued by the server, but a stale summary must not
    // leave a disabled or revoked identity with a live admin entry point.
    return capabilities is Map &&
        capabilities['access_admin'] == true &&
        (status == null || status == 'active');
  }

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
  int _windowEpoch = 0, _positionVersion = 0;
  OfficeConversationWindow? _conversationWindow;
  OfficeConversationWindow? get conversationWindow => _conversationWindow;
  int get conversationSelection => _selection;
  bool loadingMessageWindow = false;

  /// Changes on disconnect, connect, and disposal, including A → B → A.
  int get identityGeneration => _generation;
  ({int generation, String endpoint, String? principalId}) get _identity => (
    generation: _generation,
    endpoint: endpoint,
    principalId: me?['id']?.toString(),
  );
  void _requireIdentity(
    ({int generation, String endpoint, String? principalId}) identity,
  ) {
    if (_disposed || identity != _identity) {
      throw OfficeException(401, '工作身份已变化，请重新打开当前页面');
    }
  }

  bool _disposed = false;
  final Map<String, int> _reads = {};
  final Map<
    String,
    ({int sequence, int visibility, int generation, int selection})
  >
  _reading = {};
  String? _visibleConversationRoomId;
  int _conversationVisibilityVersion = 0;
  final Map<String, String> _outbox = {};

  static String newClientId() {
    final random = Random.secure();
    return 'flutter-${DateTime.now().microsecondsSinceEpoch}-${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  void _notify() {
    if (_voiceAttachmentId != null && !_voiceScopeCurrent) {
      unawaited(stopVoicePlayback());
    }
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
            'meeting_schedule_mode_unsupported':
                '关联视频会议的日程暂不支持全天、重复或取消，请先处理原会议',
            'exceptions_reset_required': '这个系列已有单次调整，请确认是否清除这些调整后再修改重复规则',
            'occurrence_not_found': '这次日程已取消或重复规则已改变，请刷新日历',
            'calendar_cursor_stale': '日历内容已变化，请重新加载当前日期范围',
            'stale_cursor': '日历内容已变化，请重新加载当前日期范围',
            'stale_occurrence': '重复规则已改变，请刷新后重新打开这次日程',
            'event_cancelled': '这条日程已取消，请刷新日历',
            'invalid_recurrence': '重复规则、开始日期或截止条件不匹配，请检查后重试',
            'invalid_timezone': '时区无效，请重新选择日程时区',
            'invalid_date': '日期范围无效，请检查开始和结束日期',
            'invalid_datetime': '所选日期或时间无效，请检查时区及起止时间',
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
        _resetMessageWindow();
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
        _resetCalendarWindow();
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
        appRecents = [];
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
    _resetCalendarWindow();
    apps = [];
    appFavorites = [];
    appRecents = [];
    _workbenchQueue = Future<void>.value();
    _workbenchPending = 0;
    _workbenchChange++;
    _workbenchRead++;
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
    _resetMessageWindow();
    _clearConversationVisibility();
    _cursor = 0;
    _reads.clear();
    _reading.clear();
    _outbox.clear();
    _notify();
  }

  Future<void> refresh() async {
    final generation = _generation;
    final results = await Future.wait<dynamic>([
      _backgroundRequest('/rooms', plugin: 'im'),
      _backgroundRequest('/principals', plugin: 'im'),
      _backgroundRequest('/agents', plugin: 'im'),
      _backgroundRequest('/agent-store', plugin: 'im'),
      _request('/library'),
      _backgroundRequest('/meetings', plugin: 'meetings'),
      _backgroundRequest('/calendar', plugin: 'calendar'),
      _refreshWorkbench(),
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
    if (_cursor == 0) _cursor = (results[0]['cursor'] as num?)?.toInt() ?? 0;
    if (selectedRoomId != null &&
        !rooms.any((r) => r['id'] == selectedRoomId)) {
      selectedRoomId = null;
      detail = null;
      _selection++;
      _resetMessageWindow();
    }
    _notify();
    await _refreshCalendarWindow();
  }

  void _resetMessageWindow() {
    _windowEpoch++;
    _conversationWindow = null;
    loadingMessageWindow = false;
  }

  int? _positiveSequence(dynamic value) =>
      value is num && value > 0 ? value.toInt() : null;

  bool _windowCurrent(
    String id,
    int selection,
    int epoch,
    ({int generation, String endpoint, String? principalId}) identity,
  ) =>
      !_disposed &&
      selectedRoomId == id &&
      selection == _selection &&
      epoch == _windowEpoch &&
      identity == _identity;

  List<Json> _mergeMessages(Iterable<Json> messages) {
    final merged = <String, Json>{};
    for (final message in messages) {
      merged[message['id']?.toString() ?? 'seq-${message['seq']}'] = message;
    }
    return merged.values.toList()
      ..sort((a, b) => (a['seq'] as num).compareTo(b['seq'] as num));
  }

  void _acceptMessageWindow(
    String id,
    Json base,
    Json page,
    List<Json> messages, {
    OfficeConversationWindow? previous,
    bool relocate = false,
    bool? startAtUnread,
    bool? hasMoreBefore,
    bool? hasMoreAfter,
    int? remainingUnreadAfter,
  }) {
    final room = base['room'] as Map? ?? {};
    final firstUnread = _positiveSequence(
      page.containsKey('first_unread_seq')
          ? page['first_unread_seq']
          : room['first_unread_seq'],
    );
    final unread =
        ((page['unread_count'] ?? room['unread_count']) as num?)?.toInt() ?? 0;
    final before =
        hasMoreBefore ??
        (page['has_more_before'] ??
                page['has_more'] ??
                page['has_more_messages']) ==
            true;
    final after = hasMoreAfter ?? page['has_more_after'] == true;
    _conversationWindow = OfficeConversationWindow(
      roomId: id,
      selection: _selection,
      positionVersion: relocate || previous == null
          ? ++_positionVersion
          : previous.positionVersion,
      entryFirstUnreadSeq: previous == null
          ? firstUnread
          : previous.entryFirstUnreadSeq,
      entryUnreadCount: previous == null
          ? max(0, unread)
          : previous.entryUnreadCount,
      anchorSeq: relocate || previous == null
          ? _positiveSequence(page['anchor_seq'])
          : previous.anchorSeq,
      firstUnreadSeq: firstUnread,
      beforeCursor: messages.isEmpty
          ? null
          : _positiveSequence(messages.first['seq']),
      afterCursor: messages.isEmpty
          ? null
          : _positiveSequence(messages.last['seq']),
      hasMoreBefore: before,
      hasMoreAfter: after,
      remainingUnreadAfter: max(
        0,
        remainingUnreadAfter ??
            (page['remaining_unread_after'] as num?)?.toInt() ??
            0,
      ),
      startAtUnread: startAtUnread ?? previous?.startAtUnread ?? false,
    );
    detail = {
      ...base,
      'messages': messages,
      'has_more_messages': before,
      'has_more_messages_after': after,
    };
  }

  Future<void> selectRoom(String id) async {
    _clearConversationVisibility();
    final selection = ++_selection, identity = _identity;
    _resetMessageWindow();
    final epoch = _windowEpoch;
    selectedRoomId = id;
    _selectAttendance();
    detail = null;
    loadingMessageWindow = true;
    error = '';
    _notify();
    try {
      final result = Json.from(
        await _backgroundRequest(
          '/rooms/${Uri.encodeComponent(id)}',
          plugin: 'im',
        ),
      );
      if (!_windowCurrent(id, selection, epoch, identity)) return;
      final room = result['room'] as Map? ?? {};
      final unread = (room['unread_count'] as num?)?.toInt() ?? 0;
      Json page = result;
      if (unread > 0) {
        page = Json.from(
          await _request(
            '/rooms/${Uri.encodeComponent(id)}/messages?first_unread=true&limit=100',
          ),
        );
        if (!_windowCurrent(id, selection, epoch, identity)) return;
      }
      _acceptMessageWindow(
        id,
        result,
        page,
        _list(page['messages']),
        startAtUnread:
            unread > 0 && _positiveSequence(page['anchor_seq']) != null,
      );
    } finally {
      if (_windowCurrent(id, selection, epoch, identity)) {
        loadingMessageWindow = false;
        _notify();
      }
    }
  }

  Future<void> _loadCurrent() async {
    final id = selectedRoomId;
    if (id == null || loadingMessageWindow) return;
    final selection = _selection, epoch = _windowEpoch, identity = _identity;
    final window = _conversationWindow;
    final previous = _list(detail?['messages']);
    final base = Json.from(
      await _backgroundRequest(
        '/rooms/${Uri.encodeComponent(id)}',
        plugin: 'im',
      ),
    );
    if (!_windowCurrent(id, selection, epoch, identity) ||
        loadingMessageWindow) {
      return;
    }
    if (window == null || previous.isEmpty) {
      _acceptMessageWindow(
        id,
        base,
        base,
        _list(base['messages']),
        previous: window,
      );
      _notify();
      return;
    }
    // Refresh the already loaded range, including edited old messages. A poll
    // must not replace an unread window with the newest tail or skip a gap.
    var cursor = (previous.first['seq'] as num).toInt() - 1;
    final end = (previous.last['seq'] as num).toInt();
    var remaining = previous.length;
    final refreshed = <Json>[];
    Json page = {};
    var before = window.hasMoreBefore;
    while (remaining > 0) {
      page = Json.from(
        await _request(
          '/rooms/${Uri.encodeComponent(id)}/messages?after=$cursor&limit=${min(200, remaining)}',
        ),
      );
      if (!_windowCurrent(id, selection, epoch, identity) ||
          loadingMessageWindow) {
        return;
      }
      if (refreshed.isEmpty) before = page['has_more_before'] == true;
      final batch = _list(page['messages']);
      if (batch.isEmpty) break;
      refreshed.addAll(batch);
      remaining -= batch.length;
      final next = (batch.last['seq'] as num).toInt();
      if (next <= cursor || page['has_more_after'] != true) break;
      cursor = next;
    }
    var messages = refreshed
        .where((message) => (message['seq'] as num).toInt() <= end)
        .toList();
    var after =
        page['has_more_after'] == true ||
        refreshed.any((message) => (message['seq'] as num).toInt() > end);
    var unreadAfter =
        (page['remaining_unread_after'] as num?)?.toInt() ??
        window.remainingUnreadAfter;
    final read = (page['read_seq'] as num?)?.toInt() ?? 0;
    unreadAfter += refreshed
        .where(
          (message) =>
              (message['seq'] as num).toInt() > end &&
              (message['seq'] as num).toInt() > read &&
              message['author_id'] != me?['id'],
        )
        .length;
    if (!window.hasMoreAfter) {
      // A previously current tail may append new arrivals, in sequence. A burst
      // larger than one page leaves a real forward window for explicit loading.
      final last = messages.isEmpty
          ? end
          : (messages.last['seq'] as num).toInt();
      page = Json.from(
        await _request(
          '/rooms/${Uri.encodeComponent(id)}/messages?after=$last&limit=100',
        ),
      );
      if (!_windowCurrent(id, selection, epoch, identity) ||
          loadingMessageWindow) {
        return;
      }
      messages = _mergeMessages([...messages, ..._list(page['messages'])]);
      after = page['has_more_after'] == true;
      unreadAfter = (page['remaining_unread_after'] as num?)?.toInt() ?? 0;
    }
    _acceptMessageWindow(
      id,
      base,
      page,
      messages,
      previous: window,
      hasMoreBefore: before,
      hasMoreAfter: after,
      remainingUnreadAfter: unreadAfter,
    );
    _notify();
  }

  Future<void> loadEarlierMessages() => _loadAdjacentMessages(later: false);

  /// Open a shared message link without first displaying/acknowledging another
  /// unread window. The target is the first row of the requested forward page.
  Future<void> focusMessage(String roomId, String messageId) async {
    _clearConversationVisibility();
    final selection = ++_selection, identity = _identity;
    _resetMessageWindow();
    final epoch = _windowEpoch;
    selectedRoomId = roomId;
    detail = null;
    loadingMessageWindow = true;
    _notify();
    try {
      final path = '/rooms/${Uri.encodeComponent(roomId)}';
      final result = await Future.wait([
        _request(path),
        _request('$path/messages/${Uri.encodeComponent(messageId)}'),
      ]);
      if (!_windowCurrent(roomId, selection, epoch, identity)) return;
      final message = Json.from(result[1]['message'] as Map);
      if (message['hidden'] == true) {
        throw OfficeException(404, '这条消息已从你的聊天中删除，可在已删除消息中恢复');
      }
      final seq = (message['seq'] as num).toInt();
      final page = Json.from(
        await _request('$path/messages?after=${seq - 1}&limit=100'),
      );
      if (!_windowCurrent(roomId, selection, epoch, identity)) return;
      final messages = _list(page['messages']);
      if (messages.isEmpty ||
          messages.first['id'] != messageId ||
          messages.first['hidden'] == true) {
        throw OfficeException(404, '目标消息已不可见，请从已删除消息中恢复或重新打开链接');
      }
      _acceptMessageWindow(
        roomId,
        Json.from(result[0]),
        {...page, 'anchor_seq': seq},
        messages,
        relocate: true,
        startAtUnread: false,
      );
    } finally {
      if (_windowCurrent(roomId, selection, epoch, identity)) {
        loadingMessageWindow = false;
        _notify();
      }
    }
  }

  Future<void> setMessagePersonal(
    String roomId,
    String messageId, {
    bool? marked,
    bool? hidden,
  }) async {
    final identity = _identity;
    await _request(
      '/rooms/${Uri.encodeComponent(roomId)}/messages/${Uri.encodeComponent(messageId)}/preferences',
      method: 'PATCH',
      data: {'marked': ?marked, 'hidden': ?hidden},
    );
    if (identity == _identity) await _updated();
  }

  Future<void> setMessageForwarding(
    String roomId,
    Json message,
    bool noForward,
  ) async {
    final identity = _identity;
    await _request(
      '/rooms/${Uri.encodeComponent(roomId)}/messages/${Uri.encodeComponent(message['id'])}/forwarding',
      method: 'PATCH',
      data: {'base_revision': message['revision'], 'no_forward': noForward},
    );
    if (identity == _identity) await _updated();
  }

  Future<void> loadLaterMessages() => _loadAdjacentMessages(later: true);

  Future<void> _loadAdjacentMessages({required bool later}) async {
    final id = selectedRoomId, base = detail, window = _conversationWindow;
    if (id == null || base == null || loadingMessageWindow) return;
    final current = _list(base['messages']);
    final hasMore = later
        ? window?.hasMoreAfter == true
        : (window?.hasMoreBefore ?? base['has_more_messages'] == true);
    if (current.isEmpty || !hasMore) return;
    final selection = _selection, identity = _identity, epoch = ++_windowEpoch;
    final cursor = (later ? current.last['seq'] : current.first['seq']) as num;
    loadingMessageWindow = true;
    _notify();
    try {
      final page = Json.from(
        await _request(
          '/rooms/${Uri.encodeComponent(id)}/messages?${later ? 'after' : 'before'}=${cursor.toInt()}&limit=100',
        ),
      );
      if (!_windowCurrent(id, selection, epoch, identity)) return;
      final merged = _mergeMessages([...current, ..._list(page['messages'])]);
      _acceptMessageWindow(
        id,
        detail!,
        page,
        merged,
        previous: window,
        hasMoreBefore: later ? window?.hasMoreBefore : null,
        hasMoreAfter: later ? null : window?.hasMoreAfter,
        remainingUnreadAfter: later ? null : window?.remainingUnreadAfter,
      );
    } finally {
      if (_windowCurrent(id, selection, epoch, identity)) {
        loadingMessageWindow = false;
        _notify();
      }
    }
  }

  Future<void> jumpToLatestMessages() async {
    final id = selectedRoomId;
    if (id == null || detail == null || loadingMessageWindow) return;
    final selection = _selection, identity = _identity, epoch = ++_windowEpoch;
    final window = _conversationWindow;
    loadingMessageWindow = true;
    _notify();
    try {
      final page = Json.from(
        await _request('/rooms/${Uri.encodeComponent(id)}/messages?limit=100'),
      );
      if (!_windowCurrent(id, selection, epoch, identity) || detail == null) {
        return;
      }
      _acceptMessageWindow(
        id,
        detail!,
        page,
        _list(page['messages']),
        previous: window,
        relocate: true,
        startAtUnread: false,
      );
    } finally {
      if (_windowCurrent(id, selection, epoch, identity)) {
        loadingMessageWindow = false;
        _notify();
      }
    }
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
      if (_voiceRoomId == roomId) await stopVoicePlayback();
      return;
    }
    if (selectedRoomId != roomId || me == null || _token.isEmpty) return;
    if (_visibleConversationRoomId != roomId) {
      _visibleConversationRoomId = roomId;
      _conversationVisibilityVersion++;
    }
  }

  /// Report only message sequences whose rendered rectangles are visible now.
  /// Captured selection and identity generation reject delayed layout reports.
  Future<void> reportVisibleMessageSequences(
    String roomId,
    Iterable<int> sequences, {
    required int selection,
    required int identityGeneration,
  }) async {
    if (_disposed ||
        selection != _selection ||
        identityGeneration != _generation ||
        _visibleConversationRoomId != roomId ||
        selectedRoomId != roomId ||
        me == null ||
        _token.isEmpty) {
      return;
    }
    final loaded = _list(detail?['messages'])
        .map((message) => _positiveSequence(message['seq']))
        .whereType<int>()
        .toSet();
    final visible = sequences.where((sequence) => loaded.contains(sequence));
    if (visible.isEmpty) return;
    await _markRead(roomId, visible.reduce(max));
  }

  Future<void> _markRead(String id, int sequence) async {
    if (_disposed || _visibleConversationRoomId != id || selectedRoomId != id) {
      return;
    }
    final generation = _generation,
        selection = _selection,
        identity = _identity,
        visibility = _conversationVisibilityVersion;
    final serverRead = rooms
        .where((room) => room['id'] == id)
        .map((room) => (room['read_seq'] as num?)?.toInt() ?? 0)
        .fold<int>(0, max);
    final pending = _reading[id];
    final pendingSequence =
        pending?.visibility == visibility &&
            pending?.generation == generation &&
            pending?.selection == selection
        ? pending!.sequence
        : 0;
    if (sequence <= max(max(_reads[id] ?? 0, serverRead), pendingSequence)) {
      return;
    }
    final receipt = (
      sequence: sequence,
      visibility: visibility,
      generation: generation,
      selection: selection,
    );
    _reading[id] = receipt;
    Json? acknowledgedRoom;
    try {
      final response = await _request(
        '/rooms/${Uri.encodeComponent(id)}/preferences',
        method: 'PATCH',
        data: {'read_seq': sequence},
      );
      if (response['room'] is Map) {
        acknowledgedRoom = Json.from(response['room']);
      }
    } finally {
      if (_reading[id] == receipt) {
        _reading.remove(id);
      }
    }
    // A receipt already sent cannot be undone. Its delayed response must not
    // alter another identity, a hidden room, or newer unread state.
    if (_disposed ||
        generation != _generation ||
        identity != _identity ||
        selection != _selection ||
        visibility != _conversationVisibilityVersion ||
        _visibleConversationRoomId != id ||
        selectedRoomId != id) {
      return;
    }
    _reads[id] = max(sequence, _reads[id] ?? 0);
    for (final room in rooms) {
      if (room['id'] == id) {
        final acknowledged = max(
          max(_reads[id]!, (room['read_seq'] as num?)?.toInt() ?? 0),
          (acknowledgedRoom?['read_seq'] as num?)?.toInt() ?? 0,
        );
        final latest = max(
          ((room['last_message'] as Map?)?['seq'] as num?)?.toInt() ?? 0,
          _list(detail?['messages']).fold<int>(
            0,
            (value, message) =>
                max(value, (message['seq'] as num?)?.toInt() ?? 0),
          ),
        );
        if (acknowledgedRoom != null &&
            (acknowledgedRoom['id'] == null || acknowledgedRoom['id'] == id) &&
            (((acknowledgedRoom['last_message'] as Map?)?['seq'] as num?)
                        ?.toInt() ??
                    0) >=
                (((room['last_message'] as Map?)?['seq'] as num?)?.toInt() ??
                    0) &&
            ((acknowledgedRoom['read_seq'] as num?)?.toInt() ?? sequence) >=
                ((room['read_seq'] as num?)?.toInt() ?? 0)) {
          for (final field in [
            'unread_count',
            'mention_count',
            'explicit_mention_count',
            'notification_count',
            'first_unread_seq',
          ]) {
            if (acknowledgedRoom.containsKey(field)) {
              room[field] = acknowledgedRoom[field];
            }
          }
        } else if (latest <= acknowledged) {
          room['unread_count'] = 0;
        }
        room['read_seq'] = acknowledged;
        _reads[id] = acknowledged;
      }
    }
    final window = _conversationWindow;
    final currentRoom = rooms.where((room) => room['id'] == id).firstOrNull;
    if (window != null && detail != null && currentRoom != null) {
      final read = (currentRoom['read_seq'] as num?)?.toInt() ?? 0;
      final remaining =
          window.afterCursor != null && read >= window.afterCursor!
          ? (currentRoom['unread_count'] as num?)?.toInt() ??
                window.remainingUnreadAfter
          : window.remainingUnreadAfter;
      _acceptMessageWindow(
        id,
        {
          ...detail!,
          'room': {...?detail!['room'] as Map?, ...currentRoom},
        },
        currentRoom,
        _list(detail!['messages']),
        previous: window,
        hasMoreBefore: window.hasMoreBefore,
        hasMoreAfter: window.hasMoreAfter,
        remainingUnreadAfter: remaining,
      );
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
    final identity = _identity;
    try {
      await refresh();
      if (identity != _identity) return;
      await refreshBusiness();
      if (identity != _identity) return;
      await _loadCurrent();
    } catch (e) {
      if (identity != _identity) return;
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
    bool mentionAll = false,
    String? sourceRoomId,
    String? replyTo,
    String? clientId,
    List<String> attachmentIds = const [],
    Json? richText,
  }) async {
    final roomId = sourceRoomId ?? selectedRoomId;
    if (roomId == null || roomId.isEmpty) {
      throw OfficeException(422, '请先选择工作会话');
    }
    final room = (detail?['room'] as Map?)?['id'] == roomId
        ? detail!['room'] as Map
        : rooms.where((room) => room['id'] == roomId).firstOrNull;
    if (mentionAll && (room == null || room['kind'] == 'direct')) {
      throw OfficeException(409, '@所有人仅可用于已加入的群聊', code: 'group_required');
    }
    final generation = _generation;
    final route = '/rooms/${Uri.encodeComponent(roomId)}/messages';
    final intent = jsonEncode([
      route,
      content,
      mentions,
      mentionAll,
      replyTo,
      attachmentIds,
      ?richText,
    ]);
    // A hot-reloaded pre-mention_all retry still represents the same false
    // intent. Move its pending key instead of duplicating an ambiguous send.
    final legacyIntent = jsonEncode([
      route,
      content,
      mentions,
      replyTo,
      attachmentIds,
    ]);
    final key =
        clientId ??
        _outbox.putIfAbsent(
          intent,
          () =>
              (!mentionAll && richText == null
                  ? _outbox.remove(legacyIntent)
                  : null) ??
              newClientId(),
        );
    final result = await _request(
      route,
      method: 'POST',
      data: {
        'client_id': key,
        'content': content,
        'rich_text': ?richText,
        'mentions': mentions,
        'mention_all': mentionAll,
        'reply_to': ?replyTo,
        'attachment_ids': attachmentIds,
      },
    );
    if (generation != _generation) {
      throw OfficeException(401, '工作身份已变化，请重新确认发送结果');
    }
    _outbox.remove(intent);
    await _updated();
    if (generation != _generation) {
      throw OfficeException(401, '工作身份已变化，请重新确认发送结果');
    }
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
    Json? richText,
  }) async {
    await _request(
      sourceRoomId == null
          ? _room('/messages/${message['id']}')
          : '/rooms/${Uri.encodeComponent(sourceRoomId)}/messages/${message['id']}',
      method: 'PATCH',
      data: {
        'content': content,
        'rich_text': richText,
        'base_revision': message['revision'] ?? 1,
      },
    );
    await _updated();
  }

  Future<void> retractMessage(Json message, {String? sourceRoomId}) async {
    await _request(
      sourceRoomId == null
          ? _room('/messages/${message['id']}')
          : '/rooms/${Uri.encodeComponent(sourceRoomId)}/messages/${message['id']}',
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
  ) => _passwordLogin(server, username, password, _identity);

  Future<void> _passwordLogin(
    String server,
    String username,
    String password,
    ({int generation, String endpoint, String? principalId}) identity,
  ) async {
    _requireIdentity(identity);
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
    _requireIdentity(identity);
    if (response.statusCode != 200) {
      throw OfficeException(
        response.statusCode,
        response.statusCode == 429 ? '尝试次数过多，请稍后重试' : '登录未完成，请检查账号、密码和服务地址',
      );
    }
    final result = Json.from(jsonDecode(response.body));
    final connecting = connect(address, result['token'] as String);
    final generation = _generation;
    await connecting;
    if (_disposed ||
        generation != _generation ||
        endpoint != address ||
        !connected) {
      throw OfficeException(401, '工作身份已变化，请重新打开当前页面');
    }
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
    final identity = _identity;
    final result = await _request('/auth/account');
    _requireIdentity(identity);
    accountInfo = Json.from(result['account'] ?? {});
    _notify();
  }

  Future<void> setAccount(
    String username,
    String password, {
    String? currentPassword,
  }) async {
    final identity = _identity;
    await _request(
      '/auth/account',
      method: 'POST',
      data: {
        'username': username,
        'password': password,
        'current_password': ?currentPassword,
      },
    );
    _requireIdentity(identity);
    // Password changes revoke browser sessions. Both requests belong to the
    // original endpoint and login attempt; a late response cannot replace a
    // different identity selected while either request was in flight.
    await _passwordLogin(identity.endpoint, username, password, identity);
  }

  Future<void> loadAccountSessions() async {
    final identity = _identity;
    final result = await _request('/auth/sessions');
    _requireIdentity(identity);
    accountSessions = _list(result['sessions']);
    _notify();
  }

  Future<void> revokeSession(String id) async {
    final identity = _identity;
    await _request(
      '/auth/sessions/${Uri.encodeComponent(id)}',
      method: 'DELETE',
      data: {},
    );
    _requireIdentity(identity);
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

  Future<void> reloadSettings() async {
    final identity = _identity;
    final result = await _request('/settings');
    _requireIdentity(identity);
    settings = Json.from(result['settings']);
    _notify();
  }

  Future<void> saveSettings(Json changes, {int? baseRevision}) async {
    final identity = _identity;
    final result = await _request(
      '/settings',
      method: 'PATCH',
      data: {
        ...changes,
        'base_revision': baseRevision ?? settings['revision'] ?? 1,
      },
    );
    _requireIdentity(identity);
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

  Future<Json> createMessageTopic(
    String roomId,
    Json rootMessage,
  ) => _createOfficeItem(
    '/rooms/${Uri.encodeComponent(roomId)}/messages/${Uri.encodeComponent(rootMessage['id'] as String)}/topic',
    {'base_revision': rootMessage['revision']},
    'topic',
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

  void _requireVoiceSource({
    required String roomId,
    required int identityGeneration,
    required int conversationSelection,
  }) {
    if (_disposed ||
        identityGeneration != _generation ||
        conversationSelection != _selection ||
        selectedRoomId != roomId ||
        me == null) {
      throw OfficeException(409, '录音所属身份或会话已变化，请重新录制');
    }
  }

  /// Stage bytes in the original room. The caller owns the stable upload ID
  /// and checks its UI scope again before it can dispatch a message.
  Future<Json> uploadVoiceAttachment(
    OfficeVoiceClip clip, {
    required String sourceRoomId,
    required int identityGeneration,
    required int conversationSelection,
    required String clientId,
  }) async {
    _requireVoiceSource(
      roomId: sourceRoomId,
      identityGeneration: identityGeneration,
      conversationSelection: conversationSelection,
    );
    if (clip.bytes.isEmpty || clip.bytes.length > 12 * 1024 * 1024) {
      throw OfficeException(422, '录音文件大小需为 1 字节至 12 MB');
    }
    final identity = _identity;
    final result = await _request(
      '/rooms/${Uri.encodeComponent(sourceRoomId)}/attachments',
      method: 'POST',
      data: {
        'client_id': clientId,
        'filename': clip.filename,
        'mime_type': clip.mimeType,
        'data_base64': base64Encode(clip.bytes),
      },
    );
    _requireIdentity(identity);
    return {...Json.from(result['attachment']), 'room_id': sourceRoomId};
  }

  /// Humans and agents submit the same voice reference. Codec, duration and
  /// kind come from the server's validation of the actual attachment bytes.
  Future<Json> sendVoiceAttachment({
    required String attachmentId,
    required String sourceRoomId,
    required int identityGeneration,
    required int conversationSelection,
    required String clientId,
  }) async {
    _requireVoiceSource(
      roomId: sourceRoomId,
      identityGeneration: identityGeneration,
      conversationSelection: conversationSelection,
    );
    final identity = _identity;
    final result = await _request(
      '/rooms/${Uri.encodeComponent(sourceRoomId)}/messages',
      method: 'POST',
      data: {
        'client_id': clientId,
        'content': '',
        'voice': {'attachment_id': attachmentId},
      },
    );
    _requireIdentity(identity);
    await _updated();
    _requireIdentity(identity);
    return Json.from(result['message']);
  }

  /// Only an unsubmitted recording may be discarded automatically. The UI
  /// never calls this after a send with an uncertain acknowledgement.
  Future<void> discardVoiceAttachment(
    Json attachment, {
    required int identityGeneration,
  }) async {
    if (_disposed || identityGeneration != _generation) return;
    final roomId = attachment['room_id'], id = attachment['id'];
    if (roomId is! String || id is! String) return;
    await _request(
      '/rooms/${Uri.encodeComponent(roomId)}/attachments/${Uri.encodeComponent(id)}',
      method: 'DELETE',
      data: {},
    );
  }

  Future<void> playVoiceAttachment(Json attachment) async {
    final roomId = attachment['room_id'] ?? selectedRoomId;
    final id = attachment['id'];
    if (roomId is! String || id is! String || roomId != selectedRoomId) {
      throw OfficeException(409, '请在语音所属会话中播放');
    }
    if ((attachment['status'] ?? attachment['availability'] ?? 'active') !=
        'active') {
      throw OfficeException(410, '这条语音已不可用');
    }
    final player = voicePlayback;
    if (_voiceAttachmentId == id && _voiceScopeCurrent && !_voiceLoading) {
      if (player.phase == OfficeVoicePlaybackPhase.playing) {
        await player.pause();
        return;
      }
      if (player.phase == OfficeVoicePlaybackPhase.paused) {
        await player.resume();
        return;
      }
    }
    final operation = ++_voiceOperation;
    _voiceIdentity = _identity;
    _voiceSelection = _selection;
    _voiceRoomId = roomId;
    _voiceAttachmentId = id;
    _voiceLoading = true;
    _voiceError = null;
    _notify();
    try {
      await player.stop();
      if (operation != _voiceOperation || !_voiceScopeCurrent) return;
      final bytes = await getAttachmentBytes({
        ...attachment,
        'room_id': roomId,
      });
      if (operation != _voiceOperation || !_voiceScopeCurrent) return;
      await player.playBytes(id: '$roomId:$id', bytes: bytes);
    } catch (e) {
      if (operation == _voiceOperation && _voiceScopeCurrent) {
        _voiceError = '语音暂时无法播放，请重试';
      }
    } finally {
      if (operation == _voiceOperation) {
        _voiceLoading = false;
        _notify();
      }
    }
  }

  Future<void> stopVoicePlayback({String? attachmentId}) async {
    if (attachmentId != null && attachmentId != _voiceAttachmentId) return;
    final operation = ++_voiceOperation;
    _voiceAttachmentId = null;
    _voiceRoomId = null;
    _voiceIdentity = null;
    _voiceLoading = false;
    _voiceError = null;
    // Invalidate downloads synchronously, but do not notify a sibling audio
    // bubble while Flutter is disposing a removed message's widget subtree.
    await Future<void>.value();
    if (operation != _voiceOperation) return;
    try {
      await _voicePlayback?.stop();
    } finally {
      _notify();
    }
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
    final results = await Future.wait<dynamic>([
      _backgroundRequest('/meetings', plugin: 'meetings'),
      _backgroundRequest('/calendar', plugin: 'calendar'),
      _refreshWorkbench(),
    ]);
    if (generation != _generation) return;
    meetings = _list(results[0]['meetings']);
    calendarEvents = _list(results[1]['events']);
    _notify();
    await _refreshCalendarWindow();
  }

  void _resetCalendarWindow() {
    _calendarRead++;
    _calendarWindow = null;
    calendarOccurrences = null;
    calendarOccurrencesLoading = false;
    calendarOccurrencesTruncated = false;
    calendarOccurrencesError = null;
    calendarNextCursor = null;
  }

  Future<void> _refreshCalendarWindow() async {
    final window = _calendarWindow;
    if (window == null) return;
    await loadCalendarOccurrences(
      from: DateTime.parse(window.from),
      to: DateTime.parse(window.to),
      timezone: window.timezone,
      force: true,
    );
  }

  Future<void> loadCalendarOccurrences({
    required DateTime from,
    required DateTime to,
    String timezone = 'Asia/Shanghai',
    bool append = false,
    bool force = false,
  }) async {
    if (!to.isAfter(from) || to.difference(from) > const Duration(days: 366)) {
      throw OfficeException(422, '请选择不超过 366 天的有效日历范围');
    }
    final window = (
      from: from.toUtc().toIso8601String(),
      to: to.toUtc().toIso8601String(),
      timezone: timezone,
    );
    if (append &&
        (_calendarWindow != window ||
            calendarNextCursor == null ||
            calendarOccurrencesLoading)) {
      return;
    }
    if (!append &&
        !force &&
        _calendarWindow == window &&
        (calendarOccurrencesLoading ||
            (calendarOccurrences != null &&
                calendarOccurrencesError == null))) {
      return;
    }
    final identity = _identity, read = ++_calendarRead;
    final changedWindow = _calendarWindow != window;
    final cursor = append ? calendarNextCursor : null;
    final preceding = append ? [...?calendarOccurrences] : <Json>[];
    _calendarWindow = window;
    if (!append) {
      if (changedWindow || calendarOccurrences == null) {
        calendarOccurrences = [];
      }
      calendarNextCursor = null;
      calendarOccurrencesTruncated = false;
    }
    calendarOccurrencesLoading = true;
    calendarOccurrencesError = null;
    _notify();
    bool current() =>
        !_disposed &&
        identity == _identity &&
        read == _calendarRead &&
        _calendarWindow == window;
    try {
      final query = Uri(
        queryParameters: {
          'from': window.from,
          'to': window.to,
          'timezone': timezone,
          'limit': '500',
          'cursor': ?cursor,
        },
      ).query;
      final result = await _backgroundRequest(
        '/calendar/occurrences?$query',
        plugin: 'calendar',
      );
      if (!current()) return;
      if (result['occurrences'] is! List) {
        throw OfficeException(502, '服务没有返回日历实例，请确认日历服务已升级');
      }
      final page = _list(result['occurrences']);
      final merged = <String, Json>{};
      for (final item in [...preceding, ...page]) {
        final key = item['occurrence_id'];
        if (key is! String || key.isEmpty) {
          throw OfficeException(502, '日历实例缺少稳定标识，请刷新后重试');
        }
        merged[key] = item;
      }
      final next = result['next_cursor'];
      if (next != null && (next is! String || next.isEmpty || next == cursor)) {
        throw OfficeException(502, '日历分页状态无效，请重新加载');
      }
      calendarOccurrences = merged.values.toList();
      calendarNextCursor = next as String?;
      calendarOccurrencesTruncated = result['truncated'] == true;
    } catch (e) {
      if (!current()) return;
      // A failed authorization or invalid page must never retain stale events.
      calendarOccurrences = [];
      calendarNextCursor = null;
      calendarOccurrencesTruncated = false;
      calendarOccurrencesError = e.toString();
    } finally {
      if (current()) {
        calendarOccurrencesLoading = false;
        _notify();
      }
    }
  }

  Future<Json> _createOfficeItem(String route, Json body, String key) async {
    final identity = _identity;
    final intent = jsonEncode([route, body]);
    final clientId = _outbox.putIfAbsent(intent, newClientId);
    final result = await _request(
      route,
      method: 'POST',
      data: {...body, 'client_id': clientId},
    );
    _requireIdentity(identity);
    _outbox.remove(intent);
    final calendarRead = route.endsWith('/calendar') ? ++_calendarRead : null;
    await _updated();
    _requireIdentity(identity);
    if (calendarRead != null && _calendarRead == calendarRead) {
      await _refreshCalendarWindow();
      _requireIdentity(identity);
    }
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
    String? startsAt,
    String? endsAt,
    bool allDay = false,
    String timezone = 'UTC',
    String? startDate,
    String? endDate,
    Json? recurrence,
    String description = '',
    String location = '',
    List<String> attendeeIds = const [],
    String? roomId,
  }) => _createOfficeItem(_businessRoom(roomId, '/calendar'), {
    'title': title,
    'starts_at': ?startsAt,
    'ends_at': ?endsAt,
    'all_day': allDay,
    'timezone': timezone,
    'start_date': ?startDate,
    'end_date': ?endDate,
    'recurrence': recurrence,
    'description': description,
    'location': location,
    'attendee_ids': attendeeIds,
  }, 'event');
  Future<Json> calendarEventDetail(String id, {String? occurrenceId}) async {
    final query = occurrenceId == null
        ? ''
        : '?${Uri(queryParameters: {'occurrence_id': occurrenceId}).query}';
    final identity = _identity;
    final calendarRead = _calendarRead;
    final visibleRooms = rooms.map((room) => room['id']).toSet();
    final result = await officeRequest(
      '/calendar/${Uri.encodeComponent(id)}$query',
    );
    _requireIdentity(identity);
    if (calendarRead != _calendarRead || !moduleAvailable('calendar')) {
      throw OfficeException(409, '日历访问状态已改变，请重新打开日程');
    }
    if (result['event'] is! Map) {
      throw OfficeException(502, '服务没有返回日程详情，请刷新后重试');
    }
    final event = Json.from(result['event']);
    if (event['id'] != id) {
      throw OfficeException(502, '服务返回的日程身份不匹配');
    }
    if (visibleRooms.contains(event['room_id']) &&
        !rooms.any((room) => room['id'] == event['room_id'])) {
      throw OfficeException(403, '你已离开日程所属会话');
    }
    final master = result['series'] is Map
        ? Json.from(result['series'])
        : event['occurrence_id'] == null
        ? event
        : null;
    if (master != null && master['id'] == id) {
      final index = calendarEvents.indexWhere((e) => e['id'] == id);
      if (index >= 0) {
        final previous = (calendarEvents[index]['revision'] as num?) ?? 0;
        if (((master['revision'] as num?) ?? 0) < previous) {
          throw OfficeException(409, '日程详情已更新，请重新打开');
        }
        calendarEvents[index] = master;
      } else {
        calendarEvents.add(master);
      }
      _notify();
    }
    return event;
  }

  Future<void> _mutateCalendar(String route, String method, Json body) async {
    final identity = _identity;
    final intent = jsonEncode(['calendar', method, route, body]);
    final clientId = _outbox.putIfAbsent(intent, newClientId);
    await _request(
      route,
      method: method,
      data: {...body, 'client_id': clientId},
    );
    _requireIdentity(identity);
    _outbox.remove(intent);
    // Discard any old window read that began before the successful mutation.
    final invalidatedRead = ++_calendarRead;
    await _updated();
    _requireIdentity(identity);
    // If the broader refresh failed before loading the calendar, still try to
    // read the authoritative result of this successful write.
    if (_calendarRead == invalidatedRead) await _refreshCalendarWindow();
  }

  Future<void> updateCalendarEvent(
    Json event,
    Json changes, {
    String? scope,
    String? occurrenceId,
    bool resetExceptions = false,
  }) => _mutateCalendar(
    '/calendar/${Uri.encodeComponent((event['event_id'] ?? event['id']).toString())}',
    'PATCH',
    {
      ...changes,
      'base_revision': event['base_revision'] ?? event['revision'],
      'scope': ?scope,
      'occurrence_id': ?occurrenceId,
      if (resetExceptions) 'reset_exceptions': true,
    },
  );

  Future<void> cancelCalendarEvent(
    Json event, {
    required String scope,
    String? occurrenceId,
  }) => _mutateCalendar(
    '/calendar/${Uri.encodeComponent((event['event_id'] ?? event['id']).toString())}',
    'DELETE',
    {
      'base_revision': event['base_revision'] ?? event['revision'],
      'scope': scope,
      'occurrence_id': ?occurrenceId,
    },
  );

  Future<void> respondCalendarEvent(
    String id,
    String response, {
    Json? event,
    String? scope,
    String? occurrenceId,
  }) =>
      _mutateCalendar('/calendar/${Uri.encodeComponent(id)}/respond', 'POST', {
        'response': response,
        if (event != null)
          'base_revision': event['base_revision'] ?? event['revision'],
        'scope': ?scope,
        'occurrence_id': ?occurrenceId,
      });

  void _acceptWorkbench(Json result) {
    apps = _list(result['apps']);
    appFavorites = List<String>.from(result['favorites'] ?? []);
    appRecents = List<String>.from(result['recents'] ?? []);
  }

  Future<void> _refreshWorkbench() async {
    // A mutation returns the complete view. Reading while it is in flight can
    // only replace that view with an older snapshot from before the write.
    if (_workbenchPending > 0) return;
    final identity = _identity,
        read = ++_workbenchRead,
        change = _workbenchChange;
    final result = await _backgroundRequest('/workbench', plugin: 'workbench');
    if (_disposed ||
        identity != _identity ||
        read != _workbenchRead ||
        change != _workbenchChange ||
        _workbenchPending > 0) {
      return;
    }
    _acceptWorkbench(Json.from(result));
    _notify();
  }

  Future<void> _mutateWorkbench(
    String path, {
    required String method,
    Json? data,
    String? visitAppId,
  }) {
    final identity = _identity;
    _workbenchPending++;
    _workbenchChange++;
    // Serialize personal preference writes, retaining click order even if the
    // network would otherwise process or return them in the opposite order.
    final operation = _workbenchQueue
        .then((_) async {
          _requireIdentity(identity);
          if (visitAppId != null) {
            final app = apps
                .where((item) => item['id'] == visitAppId)
                .firstOrNull;
            if (app == null) {
              throw OfficeException(404, '此应用已不存在', code: 'app_not_found');
            }
            if (!moduleAvailable('workbench') || app['available'] != true) {
              throw OfficeException(403, '当前身份暂时无法使用此应用');
            }
          }
          final result = await _request(path, method: method, data: data);
          _requireIdentity(identity);
          _acceptWorkbench(Json.from(result));
          _notify();
        })
        .whenComplete(() {
          if (!_disposed && identity == _identity) {
            _workbenchPending--;
            _workbenchChange++;
          }
        });
    // A failed write must surface to its caller without poisoning later writes.
    _workbenchQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> setAppFavorites(List<String> favorites) => _mutateWorkbench(
    '/workbench',
    method: 'PATCH',
    data: {'favorites': List<String>.of(favorites)},
  );

  Future<void> recordWorkbenchVisit(String appId) => _mutateWorkbench(
    '/workbench/recents',
    method: 'POST',
    data: {'app_id': appId},
    visitAppId: appId,
  );

  Future<void> clearWorkbenchRecents() =>
      _mutateWorkbench('/workbench/recents', method: 'DELETE');

  Future<String> exportRoom() async =>
      await _request(_room('/export'), text: true) as String;

  @override
  void dispose() {
    _disposed = true;
    _voiceOperation++;
    _voicePlayback?.dispose();
    _clearConversationVisibility();
    _generation++;
    _client.close();
    super.dispose();
  }
}
