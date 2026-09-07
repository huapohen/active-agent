import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart' show friendlyError;
import 'office_emoji.dart';
import 'office_theme.dart';

String _urgencyPath(String roomId) =>
    '/rooms/${Uri.encodeComponent(roomId)}/urgencies';
final _pendingUrgencies = Expando<Map<String, Json>>(
  'pending-in-app-urgencies',
);

Future<T?> _showUrgencyPanel<T>(BuildContext context, Widget panel) {
  if (MediaQuery.sizeOf(context).width < 720) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final keyboard = MediaQuery.viewInsetsOf(context).bottom;
          final available = (constraints.maxHeight - keyboard).clamp(
            0.0,
            double.infinity,
          );
          return Padding(
            padding: EdgeInsets.only(bottom: keyboard),
            child: SizedBox(
              height: (MediaQuery.sizeOf(context).height * .88).clamp(
                0.0,
                available,
              ),
              child: panel,
            ),
          );
        },
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 550,
        height: MediaQuery.sizeOf(context).height * .82,
        child: panel,
      ),
    ),
  );
}

/// Returns the actual created request when the successful composer is closed.
Future<Json?> showOfficeMessageUrgency(
  BuildContext context,
  OfficeState state,
  String roomId,
  Json message,
) => _showUrgencyPanel<Json>(
  context,
  OfficeMessageUrgencyComposer(
    state: state,
    roomId: roomId,
    messageId: str(message['id']),
  ),
);

Future<bool?> showOfficeMessageUrgencyDetail(
  BuildContext context,
  OfficeState state,
  String roomId,
  String urgencyId,
) => _showUrgencyPanel<bool>(
  context,
  OfficeMessageUrgencyDetail(
    state: state,
    roomId: roomId,
    urgencyId: urgencyId,
  ),
);

Future<void> showOfficeRoomUrgencies(
  BuildContext context,
  OfficeState state,
  String roomId,
) async {
  await _showUrgencyPanel<void>(
    context,
    OfficeRoomUrgencies(state: state, roomId: roomId),
  );
}

abstract class _UrgencyScope<T extends StatefulWidget> extends State<T> {
  OfficeState get office;
  String get sourceRoom;
  late final OfficeState boundOffice;
  late final (int, String, String, String) identity;
  bool expired = false;
  int intent = 0;
  bool get current =>
      !expired &&
      mounted &&
      identical(office, boundOffice) &&
      office.me != null &&
      identity ==
          (
            office.identityGeneration,
            office.endpoint,
            personId(office.me ?? {}),
            sourceRoom,
          );
  @override
  void initState() {
    super.initState();
    boundOffice = office;
    identity = (
      office.identityGeneration,
      office.endpoint,
      personId(office.me ?? {}),
      sourceRoom,
    );
    boundOffice.addListener(_scopeChanged);
  }

  void clearPrivate();
  void refreshChanged() {}
  void invalidate() {
    expired = true;
    intent++;
    clearPrivate();
  }

  void _scopeChanged() {
    if (!mounted) return;
    if (!current) {
      setState(invalidate);
      return;
    }
    setState(() {});
    refreshChanged();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!current) invalidate();
  }

  @override
  void dispose() {
    intent++;
    boundOffice.removeListener(_scopeChanged);
    super.dispose();
  }
}

Json _validateUrgency(dynamic raw, OfficeState office, String roomId) {
  if (raw is! Map ||
      str(raw['id']).isEmpty ||
      raw['room_id'] != roomId ||
      raw['recipients'] is! List ||
      (raw['message'] is! Map &&
          !(raw['source_status'] == 'missing' && raw['message'] == null))) {
    throw const FormatException('加急记录来源不完整');
  }
  final value = Json.from(jsonDecode(jsonEncode(raw)) as Map);
  if (value['source_status'] == 'missing' && value['message'] == null) {
    value['message'] = {'id': value['message_id'], 'content': ''};
  }
  final self = personId(office.me ?? {});
  final sender =
      value['summary_scope'] == 'sender' && value['created_by'] == self;
  if (value['summary_scope'] == 'sender' && !sender) {
    throw const FormatException('加急记录的查看身份不匹配');
  }
  final recipients = maps(value['recipients'])
      .where((r) => sender || r['principal_id'] == self)
      .toList();
  if (!sender && recipients.isEmpty) {
    throw const FormatException('当前身份不是该加急的接收成员');
  }
  value['recipients'] = recipients;
  value['counts'] = {
    'total': recipients.length,
    'acknowledged': recipients
        .where((r) => r['status'] == 'acknowledged')
        .length,
    'pending': recipients.where((r) => r['status'] == 'pending').length,
    'unavailable': recipients.where((r) => r['status'] == 'unavailable').length,
  };
  final message = Json.from(value['message'] as Map);
  if (message['id'] != value['message_id']) {
    throw const FormatException('加急来源消息不匹配');
  }
  if (message['hidden'] == true ||
      value['source_status'] == 'hidden' ||
      message['retracted_at'] != null ||
      value['source_status'] == 'retracted') {
    value['message'] = {
      'id': message['id'],
      'hidden': message['hidden'] == true || value['source_status'] == 'hidden',
      'retracted_at': message['retracted_at'],
      'content': '',
    };
  }
  value['can_ack'] =
      value['can_ack'] == true &&
      value['source_status'] == 'current' &&
      message['hidden'] != true &&
      message['retracted_at'] == null &&
      recipients.any(
        (r) =>
            r['principal_id'] == self &&
            r['status'] == 'pending' &&
            r['current_member'] == true &&
            r['same_membership'] == true,
      );
  return value;
}

String _requestStatus(Json value) {
  if ((value['message'] as Map?)?['hidden'] == true) return '来源消息已为你隐藏';
  return switch (str(value['status'])) {
    'source_retracted' => '来源消息已撤回',
    'source_changed' => '来源消息已更新，原加急不可再确认',
    'acknowledged' || 'completed' || 'complete' => '已确认',
    'unavailable' => '接收成员已不可达',
    'sender_unavailable' => '发起成员已不可达',
    'source_missing' => '来源消息已不可用',
    'source_hidden' => '来源消息已为你隐藏',
    'pending' || 'active' => '等待确认',
    _ => str(value['status'], '加急状态待刷新'),
  };
}

Widget _urgencySource(Json value, {bool compact = false}) {
  if (value['source_status'] == 'missing') {
    return const Text(
      '来源消息已不可用',
      style: TextStyle(fontSize: 12, color: mutedColor),
    );
  }
  final message = Json.from(value['message'] as Map? ?? {});
  final hidden = message['hidden'] == true;
  final retracted =
      message['retracted_at'] != null || value['source_status'] == 'retracted';
  if (hidden || retracted) {
    return Text(
      hidden ? '这条消息已从你的聊天中删除' : '来源消息已撤回',
      style: const TextStyle(fontSize: 12, color: mutedColor),
    );
  }
  if (compact) {
    return Text(
      str(message['content'], '附件消息').replaceAll('\n', ' '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13),
    );
  }
  return OfficeEmojiText(
    content: str(message['content'], '附件消息'),
    selectable: false,
  );
}

Widget _urgencyHeader(
  String title, {
  VoidCallback? onRefresh,
  required VoidCallback onClose,
}) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 8, 6, 4),
  child: Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      if (onRefresh != null)
        IconButton(
          tooltip: '刷新加急',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 20),
        ),
      IconButton(
        tooltip: '关闭加急',
        onPressed: onClose,
        icon: const Icon(Icons.close, size: 20),
      ),
    ],
  ),
);

Widget _urgencyError(String? message) => message == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          message,
          style: const TextStyle(fontSize: 12, color: Colors.redAccent),
        ),
      );
const _expiredUrgency = Center(child: Text('工作身份或来源会话已变化，请关闭后重新打开加急。'));

class OfficeMessageUrgencyComposer extends StatefulWidget {
  const OfficeMessageUrgencyComposer({
    super.key,
    required this.state,
    required this.roomId,
    required this.messageId,
  });
  final OfficeState state;
  final String roomId, messageId;
  @override
  State<OfficeMessageUrgencyComposer> createState() =>
      _OfficeMessageUrgencyComposerState();
}

class _OfficeMessageUrgencyComposerState
    extends _UrgencyScope<OfficeMessageUrgencyComposer> {
  @override
  OfficeState get office => widget.state;
  @override
  String get sourceRoom => widget.roomId;
  late final String _messageId, _pendingKey;
  final _search = TextEditingController();
  final _bodyScroll = ScrollController();
  bool _moreBelow = false, _scrollCheckQueued = false;
  final _selected = <String>{};
  List<Json> _members = [];
  Json? _source, _pending, _created;
  String? _error, _blocked, _unreadError, _unreadNotice;
  bool _busy = false, _ready = false, _needsReview = false;
  @override
  void initState() {
    super.initState();
    _bodyScroll.addListener(_scheduleScrollStatus);
    _messageId = widget.messageId;
    _pendingKey = jsonEncode([
      identity.$1,
      identity.$2,
      identity.$3,
      sourceRoom,
      _messageId,
    ]);
    _pending = _pendingUrgencies[office]?[_pendingKey];
    if (_pending != null) {
      _selected.addAll((_pending!['recipient_ids'] as List).cast<String>());
    }
    _load();
  }

  @override
  void clearPrivate() {
    _search.clear();
    _selected.clear();
    _members = [];
    _source = _pending = _created = null;
    _error = _blocked = _unreadError = _unreadNotice = null;
    _busy = _ready = false;
    _moreBelow = false;
  }

  @override
  void didUpdateWidget(covariant OfficeMessageUrgencyComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messageId != _messageId) invalidate();
  }

  @override
  void dispose() {
    _bodyScroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _scheduleScrollStatus() {
    if (_scrollCheckQueued || !mounted) return;
    _scrollCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCheckQueued = false;
      if (!mounted) return;
      final more =
          current &&
          _bodyScroll.hasClients &&
          _bodyScroll.position.extentAfter > 12;
      if (_moreBelow != more) setState(() => _moreBelow = more);
    });
  }

  Future<(Json, List<Json>)> _readSource() async {
    final path = '/rooms/${Uri.encodeComponent(sourceRoom)}';
    final results = await Future.wait([
      office.officeRequest(path),
      office.officeRequest('$path/messages/${Uri.encodeComponent(_messageId)}'),
    ]);
    if ((results[0]['room'] as Map?)?['id'] != sourceRoom ||
        (results[1]['message'] as Map?)?['id'] != _messageId) {
      throw const FormatException('加急来源会话或消息不匹配');
    }
    final source = Json.from(results[1]['message'] as Map);
    if (source['author_id'] != identity.$3) {
      throw OfficeException(403, '只能为自己发送的消息发起加急');
    }
    if (source['retracted_at'] != null || source['hidden'] == true) {
      throw OfficeException(409, '来源消息已删除或撤回，不能发起加急');
    }
    if (source['revision'] is! num) throw const FormatException('来源消息缺少版本');
    final unique = <String, Json>{};
    for (final member in maps(results[0]['members'])) {
      final id = personId(member);
      if (id.isNotEmpty && id != identity.$3) unique[id] = member;
    }
    return (source, unique.values.toList());
  }

  Future<void> _load() async {
    if (!current || !office.connected || _busy) return;
    final request = ++intent;
    setState(() {
      _busy = true;
      _error = _blocked = null;
    });
    try {
      final source = await _readSource();
      if (!current || request != intent) return;
      setState(() {
        _source = source.$1;
        _members = source.$2;
        _ready = true;
        _needsReview = false;
      });
    } catch (e) {
      if (current && request == intent) {
        setState(() {
          _source = null;
          _members = [];
          _ready = false;
          _error = friendlyError(e);
          if (e is OfficeException && e.status < 500) _blocked = _error;
        });
      }
    } finally {
      if (current && request == intent) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (!current ||
        !office.connected ||
        _busy ||
        _created != null ||
        (_pending == null &&
            (!_ready ||
                _needsReview ||
                _selected.isEmpty ||
                _blocked != null))) {
      return;
    }
    final request = ++intent;
    setState(() {
      _busy = true;
      _error = null;
    });
    var posted = false;
    try {
      if (_pending == null) {
        final fresh = await _readSource();
        if (!current || request != intent) return;
        final valid = fresh.$2.map(personId).toSet();
        if (!_selected.every(valid.contains)) {
          setState(() {
            _members = fresh.$2;
            _selected.retainAll(valid);
            _error = '接收成员已变化，请检查选择后重新发送。';
          });
          return;
        }
        if (_source?['revision'] != fresh.$1['revision']) {
          setState(() {
            _source = fresh.$1;
            _error = '来源消息已更新，请检查新内容后重新发送。';
          });
          return;
        }
        _pending = {
          'client_id': OfficeState.newClientId(),
          'base_revision': fresh.$1['revision'],
          'recipient_ids': _selected.toList(),
          'channel': 'in_app',
        };
        (_pendingUrgencies[office] ??= {})[_pendingKey] = Json.from(
          jsonDecode(jsonEncode(_pending)) as Map,
        );
      }
      posted = true;
      final result = await office.officeRequest(
        '/rooms/${Uri.encodeComponent(sourceRoom)}/messages/${Uri.encodeComponent(_messageId)}/urgencies',
        method: 'POST',
        data: _pending,
      );
      if (!current || request != intent) return;
      final created = _validateUrgency(result['urgency'], office, sourceRoom);
      _pendingUrgencies[office]?.remove(_pendingKey);
      setState(() {
        _created = created;
        _pending = null;
      });
    } catch (e) {
      if (current && request == intent) {
        setState(() {
          _error = friendlyError(e);
          if (e is OfficeException && (e.status == 403 || e.status == 404)) {
            _source = null;
            _members = [];
            _selected.clear();
            _search.clear();
            _ready = false;
            _needsReview = true;
            _blocked = _error;
            _unreadError = _unreadNotice = null;
          }
          if (posted &&
              e is OfficeException &&
              e.status >= 400 &&
              e.status < 500 &&
              e.code != 'idempotency_conflict') {
            _pendingUrgencies[office]?.remove(_pendingKey);
            _pending = null;
            _needsReview = true;
          } else if (posted && _pending != null) {
            _error =
                '发送结果尚未确认。已保留同一次加急，请重试确认，避免重复发送。${e is OfficeException && e.code == 'idempotency_conflict' ? '请求标识冲突，请核对已发送记录。' : ''}';
          }
        });
      }
    } finally {
      if (current && request == intent) setState(() => _busy = false);
    }
  }

  Future<void> _selectUnread() async {
    if (!current ||
        !office.connected ||
        _busy ||
        !_ready ||
        _pending != null ||
        _created != null ||
        _needsReview ||
        _blocked != null) {
      return;
    }
    final request = ++intent;
    setState(() {
      _busy = true;
      _unreadError = _unreadNotice = null;
    });
    try {
      final sourceFuture = _readSource();
      final readersFuture = office.officeRequest(
        '/rooms/${Uri.encodeComponent(sourceRoom)}/messages/${Uri.encodeComponent(_messageId)}/readers',
      );
      final results = await Future.wait<Object>([sourceFuture, readersFuture]);
      if (!current || request != intent) return;
      final fresh = results[0] as (Json, List<Json>);
      final reading = results[1] as Json;
      if (reading['message_id'] != _messageId ||
          reading['receipt_summary'] is! Map ||
          reading['readers'] is! List) {
        throw const FormatException('阅读状态与来源消息不匹配');
      }
      final valid = fresh.$2.map(personId).toSet();
      if (_source?['revision'] != fresh.$1['revision']) {
        setState(() {
          _source = fresh.$1;
          _members = fresh.$2;
          _selected.retainAll(valid);
          _unreadError = '来源消息已更新，请检查新内容后再次选择未读成员。';
        });
        return;
      }
      final summary = reading['receipt_summary'] as Map;
      if (summary['known'] != true || summary['basis'] != 'explicit_read_ack') {
        setState(() => _unreadError = '阅读状态未知，不能自动选择未读成员。可以重试读取或手动选择。');
        return;
      }
      final unread = maps(reading['readers'])
          .where(
            (reader) =>
                reader['status'] == 'unread' &&
                reader['read'] == false &&
                reader['current_member'] == true &&
                reader['same_membership'] == true &&
                valid.contains(personId(reader)),
          )
          .map(personId)
          .toSet();
      final selected = _selected.intersection(valid)..addAll(unread);
      if (selected.length > 100) {
        setState(() => _unreadError = '未读成员与当前选择合计超过 100 人，请分批手动选择。');
        return;
      }
      setState(() {
        _source = fresh.$1;
        _members = fresh.$2;
        _selected
          ..clear()
          ..addAll(selected);
        _unreadNotice = unread.isEmpty
            ? '当前没有可加急的未读成员。'
            : '已选中 ${unread.length} 位当前未读成员。';
      });
    } catch (e) {
      if (current && request == intent) {
        setState(() {
          _unreadError = '未读成员读取失败，未自动选择。${friendlyError(e)}';
          if (e is OfficeException && (e.status == 403 || e.status == 404)) {
            _source = null;
            _members = [];
            _selected.clear();
            _ready = false;
            _blocked = friendlyError(e);
          }
        });
      }
    } finally {
      if (current && request == intent) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final shown = _members
        .where(
          (m) =>
              '${officeDisplayName(m)} ${m['name']} ${m['kind'] == 'agent' ? 'Agent' : '人类'}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    final edit = current && !_busy && _pending == null && _created == null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
      },
      child: Focus(
        autofocus: MediaQuery.sizeOf(context).width >= 720,
        child: Material(
          color: Colors.white,
          child: SafeArea(
            child: Column(
              children: [
                _urgencyHeader(
                  _created == null ? '加急消息' : '加急已发出',
                  onClose: () =>
                      Navigator.pop(context, current ? _created : null),
                ),
                const Divider(height: 1),
                Expanded(
                  child: !current
                      ? _expiredUrgency
                      : ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context)
                              .copyWith(scrollbars: false),
                          child: Scrollbar(
                            controller: _bodyScroll,
                            thumbVisibility: true,
                            child: NotificationListener<ScrollMetricsNotification>(
                              onNotification: (_) {
                                _scheduleScrollStatus();
                                return false;
                              },
                              child: ListView(
                                key: const ValueKey('urgency-scroll-body'),
                                controller: _bodyScroll,
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.onDrag,
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  16,
                                ),
                                children: [
                                  if (!office.connected)
                                    const Text('当前离线，重新连接后才能发送加急。'),
                                  _urgencyError(_error),
                                  if (_busy)
                                    const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  if (_created != null) ...[
                                    _urgencySource(_created!),
                                    const SizedBox(height: 12),
                                    Text(
                                      _requestStatus(_created!),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      '${(_created!['counts'] as Map)['acknowledged']} 已确认 · ${(_created!['counts'] as Map)['pending']} 待确认',
                                    ),
                                    TextButton(
                                      onPressed: office.connected
                                          ? () =>
                                                showOfficeMessageUrgencyDetail(
                                                  context,
                                                  office,
                                                  sourceRoom,
                                                  str(_created!['id']),
                                                )
                                          : null,
                                      child: const Text('查看确认详情'),
                                    ),
                                  ] else ...[
                                    if (_source != null)
                                      Card(
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: OfficeEmojiText(
                                            content: str(
                                              _source!['content'],
                                              '附件消息',
                                            ),
                                            selectable: false,
                                          ),
                                        ),
                                      ),
                                    if (_pending != null)
                                      const Text(
                                        '正在确认上一次发送结果，接收人已锁定。重试会复用原加急请求。',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: mutedColor,
                                        ),
                                      ),
                                    if (!_ready || _needsReview)
                                      TextButton(
                                        onPressed: _busy || !office.connected
                                            ? null
                                            : _load,
                                        child: const Text('重新核对来源与成员'),
                                      ),
                                    Text(
                                      '选择接收成员 · 已选 ${_selected.length} 人',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    TextField(
                                      key: const ValueKey(
                                        'urgency-member-search',
                                      ),
                                      controller: _search,
                                      enabled: edit,
                                      decoration: const InputDecoration(
                                        hintText: '搜索群内人或 Agent',
                                        prefixIcon: Icon(Icons.search),
                                        isDense: true,
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton.icon(
                                        key: const ValueKey(
                                          'urgency-select-unread',
                                        ),
                                        onPressed:
                                            edit &&
                                                office.connected &&
                                                _ready &&
                                                !_needsReview &&
                                                _blocked == null
                                            ? _selectUnread
                                            : null,
                                        icon: const Icon(
                                          Icons.done_all,
                                          size: 18,
                                        ),
                                        label: Text(
                                          _unreadError == null
                                              ? '全选未读成员'
                                              : '重试读取未读成员',
                                        ),
                                      ),
                                    ),
                                    _urgencyError(_unreadError),
                                    if (_unreadNotice != null)
                                      Text(
                                        _unreadNotice!,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: mutedColor,
                                        ),
                                      ),
                                    if (_ready && _members.isEmpty)
                                      const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Text('当前会话没有其他可接收成员'),
                                      ),
                                    for (final member in shown)
                                      CheckboxListTile(
                                        key: ValueKey(
                                          'urgency-recipient-${personId(member)}',
                                        ),
                                        value: _selected.contains(
                                          personId(member),
                                        ),
                                        onChanged: !edit
                                            ? null
                                            : (checked) => setState(() {
                                                final id = personId(member);
                                                if (checked == true) {
                                                  if (_selected.length >= 100) {
                                                    _error = '一次最多加急 100 位成员';
                                                  } else {
                                                    _selected.add(id);
                                                  }
                                                } else {
                                                  _selected.remove(id);
                                                }
                                              }),
                                        contentPadding: EdgeInsets.zero,
                                        dense: true,
                                        visualDensity: VisualDensity.compact,
                                        controlAffinity:
                                            ListTileControlAffinity.leading,
                                        title: Text(officeDisplayName(member)),
                                        subtitle: Text(
                                          member['kind'] == 'agent'
                                              ? 'Agent 同事'
                                              : '人类同事',
                                        ),
                                        secondary: PersonAvatar(
                                          name: officeDisplayName(member),
                                          agent: member['kind'] == 'agent',
                                          size: 30,
                                        ),
                                      ),
                                    const Divider(height: 24),
                                    const Text(
                                      '发送方式',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    RadioGroup<String>(
                                      groupValue: 'in_app',
                                      onChanged: (_) {},
                                      child: Column(
                                        children: [
                                          RadioListTile<String>(
                                            key: const ValueKey(
                                              'urgency-channel-in-app',
                                            ),
                                            value: 'in_app',
                                            enabled: edit,
                                            dense: true,
                                            visualDensity:
                                                VisualDensity.compact,
                                            contentPadding: EdgeInsets.zero,
                                            title: const Text('仅应用内'),
                                            subtitle: const Text(
                                              '接收成员需主动确认，阅读不等于确认。',
                                            ),
                                          ),
                                          const RadioListTile<String>(
                                            key: ValueKey(
                                              'urgency-channel-sms',
                                            ),
                                            value: 'in_app_sms',
                                            enabled: false,
                                            dense: true,
                                            visualDensity:
                                                VisualDensity.compact,
                                            contentPadding: EdgeInsets.zero,
                                            title: Text('应用内 + 短信'),
                                            subtitle: Text('短信渠道未配置，暂不可用'),
                                          ),
                                          const RadioListTile<String>(
                                            key: ValueKey(
                                              'urgency-channel-phone',
                                            ),
                                            value: 'in_app_phone',
                                            enabled: false,
                                            dense: true,
                                            visualDensity:
                                                VisualDensity.compact,
                                            contentPadding: EdgeInsets.zero,
                                            title: Text('应用内 + 电话'),
                                            subtitle: Text(
                                              '电话渠道未配置，暂不可用',
                                              key: ValueKey(
                                                'urgency-phone-status',
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
                if (current && _created == null)
                  Padding(
                    key: const ValueKey('urgency-fixed-actions'),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_moreBelow)
                          const Padding(
                            key: ValueKey('urgency-scroll-hint'),
                            padding: EdgeInsets.only(bottom: 6),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.keyboard_arrow_down,
                                  size: 16,
                                  color: mutedColor,
                                ),
                                Flexible(
                                  child: Text(
                                    '下方还有成员或发送方式，继续滚动查看',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: mutedColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                key: const ValueKey('urgency-send'),
                                onPressed:
                                    !office.connected ||
                                        _busy ||
                                        (_pending == null &&
                                            (!_ready ||
                                                _needsReview ||
                                                _selected.isEmpty ||
                                                _blocked != null))
                                    ? null
                                    : _send,
                                child: Text(
                                  _pending != null
                                      ? '重试确认同一次发送'
                                      : MediaQuery.sizeOf(context).width < 720
                                      ? '加急 发送'
                                      : Theme.of(context).platform ==
                                            TargetPlatform.macOS
                                      ? '加急 发送 ⌘+Enter'
                                      : '加急 发送 Ctrl+Enter',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OfficeMessageUrgencyDetail extends StatefulWidget {
  const OfficeMessageUrgencyDetail({
    super.key,
    required this.state,
    required this.roomId,
    required this.urgencyId,
  });
  final OfficeState state;
  final String roomId, urgencyId;
  @override
  State<OfficeMessageUrgencyDetail> createState() =>
      _OfficeMessageUrgencyDetailState();
}

class _OfficeMessageUrgencyDetailState
    extends _UrgencyScope<OfficeMessageUrgencyDetail> {
  @override
  OfficeState get office => widget.state;
  @override
  String get sourceRoom => widget.roomId;
  late final String _urgencyId;
  Json? _value;
  String? _error;
  bool _busy = false, _changed = false, _queued = false;
  String get path =>
      '${_urgencyPath(sourceRoom)}/${Uri.encodeComponent(_urgencyId)}';
  @override
  void initState() {
    super.initState();
    _urgencyId = widget.urgencyId;
    _load();
  }

  @override
  void clearPrivate() {
    _value = null;
    _error = null;
    _busy = false;
  }

  @override
  void didUpdateWidget(covariant OfficeMessageUrgencyDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.urgencyId != _urgencyId) invalidate();
  }

  @override
  void refreshChanged() {
    if (!office.connected || _busy || _queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (current && !_busy && office.connected) _load();
    });
  }

  Future<void> _load({bool ack = false}) async {
    if (!current ||
        !office.connected ||
        _busy ||
        (ack && _value?['can_ack'] != true)) {
      return;
    }
    final request = ++intent;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await office.officeRequest(
        '$path${ack ? '/ack' : ''}',
        method: ack ? 'POST' : 'GET',
        data: ack ? {} : null,
      );
      if (!current || request != intent) return;
      final value = _validateUrgency(response['urgency'], office, sourceRoom);
      if (value['id'] != _urgencyId) throw const FormatException('加急记录不匹配');
      setState(() {
        _value = value;
        if (ack) _changed = true;
      });
    } catch (e) {
      if (current && request == intent) {
        setState(() {
          _error = friendlyError(e);
          if (ack &&
              !(e is OfficeException && (e.status == 403 || e.status == 404))) {
            _value = {...?_value, 'can_ack': false};
          } else {
            _value = null;
          }
        });
      }
    } finally {
      if (current && request == intent) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: SafeArea(
      child: Column(
        children: [
          _urgencyHeader(
            '加急确认',
            onRefresh: current && office.connected && !_busy ? _load : null,
            onClose: () => Navigator.pop(context, _changed),
          ),
          const Divider(height: 1),
          Expanded(
            child: !current
                ? _expiredUrgency
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (!office.connected) const Text('当前离线，确认操作暂不可用。'),
                      _urgencyError(_error),
                      if (_error != null)
                        TextButton(
                          onPressed: _busy || !office.connected ? null : _load,
                          child: const Text('重新加载加急'),
                        ),
                      if (_busy)
                        const Center(child: CircularProgressIndicator()),
                      if (_value != null) ...[
                        _urgencySource(_value!),
                        const SizedBox(height: 12),
                        Text(
                          _requestStatus(_value!),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _value!['summary_scope'] == 'sender'
                              ? '${(_value!['counts'] as Map)['acknowledged']} 已确认 · ${(_value!['counts'] as Map)['pending']} 待确认 · ${(_value!['counts'] as Map)['unavailable']} 不可达'
                              : '仅展示你的确认状态',
                          style: const TextStyle(
                            fontSize: 12,
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 12),
                        for (final person in maps(_value!['recipients']))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: PersonAvatar(
                              name: str(person['name']),
                              agent: person['kind'] == 'agent',
                              size: 32,
                            ),
                            title: Text(str(person['name'])),
                            subtitle: Text(
                              [
                                person['kind'] == 'agent' ? 'Agent 同事' : '人类同事',
                                if (person['current_member'] == false)
                                  '已离开会话'
                                else if (person['same_membership'] == false)
                                  '成员身份已变化',
                                if (person['acknowledged_at'] != null)
                                  clockText(
                                    person['acknowledged_at'],
                                    date: true,
                                    context: context,
                                  ),
                              ].join(' · '),
                            ),
                            trailing: Text(
                              switch (str(person['status'])) {
                                'acknowledged' => '已确认',
                                'unavailable' => '不可达',
                                'pending' => '待确认',
                                _ => '状态未知',
                              },
                              style: TextStyle(
                                color: person['status'] == 'acknowledged'
                                    ? accentColor
                                    : mutedColor,
                              ),
                            ),
                          ),
                        if (_value!['can_ack'] == true)
                          FilledButton(
                            key: const ValueKey('urgency-acknowledge'),
                            onPressed: _busy || !office.connected
                                ? null
                                : () => _load(ack: true),
                            child: const Text('我已知晓'),
                          ),
                        const SizedBox(height: 12),
                        const Text(
                          '加急确认独立于消息已读；只有指定接收成员可以确认自己的状态。',
                          style: TextStyle(fontSize: 12, color: mutedColor),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}

class OfficeRoomUrgencies extends StatefulWidget {
  const OfficeRoomUrgencies({
    super.key,
    required this.state,
    required this.roomId,
  });
  final OfficeState state;
  final String roomId;
  @override
  State<OfficeRoomUrgencies> createState() => _OfficeRoomUrgenciesState();
}

class _OfficeRoomUrgenciesState extends _UrgencyScope<OfficeRoomUrgencies> {
  @override
  OfficeState get office => widget.state;
  @override
  String get sourceRoom => widget.roomId;
  String _box = 'inbox';
  bool _pendingOnly = true, _busy = false, _more = false, _queued = false;
  int? _before;
  List<Json> _items = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void clearPrivate() {
    _items = [];
    _before = null;
    _error = null;
    _busy = _more = false;
  }

  @override
  void refreshChanged() {
    if (!office.connected || _busy || _queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (current && !_busy && office.connected) _load();
    });
  }

  Future<void> _load({bool more = false}) async {
    if (!current ||
        !office.connected ||
        _busy ||
        (more && (!_more || _before == null))) {
      return;
    }
    final request = ++intent;
    final before = more ? _before : null;
    final query = Uri(
      queryParameters: {
        'box': _box,
        'status': _pendingOnly ? 'pending' : 'all',
        'limit': '50',
        if (before != null) 'before': '$before',
      },
    ).query;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await office.officeRequest(
        '${_urgencyPath(sourceRoom)}?$query',
      );
      if (!current || request != intent) return;
      final next = (response['next_before'] as num?)?.toInt();
      final hasMore = response['has_more'] == true;
      if (response['items'] is! List ||
          (hasMore &&
              (next == null ||
                  next < 1 ||
                  (before != null && next >= before)))) {
        throw const FormatException('加急记录分页未前进，请刷新');
      }
      final incoming = (response['items'] as List).map(
        (value) => _validateUrgency(value, office, sourceRoom),
      );
      final unique = <String, Json>{
        if (more)
          for (final item in _items) str(item['id']): item,
      };
      for (final item in incoming) {
        unique[str(item['id'])] = item;
      }
      setState(() {
        _items = unique.values.toList();
        _before = next;
        _more = hasMore;
      });
    } catch (e) {
      if (current && request == intent) {
        setState(() {
          _error = friendlyError(e);
          if (!more ||
              (e is OfficeException && (e.status == 403 || e.status == 404))) {
            _items = [];
            _more = false;
            _before = null;
          }
        });
      }
    } finally {
      if (current && request == intent) setState(() => _busy = false);
    }
  }

  Future<void> _open(Json value) async {
    if (!current || _busy || !office.connected) return;
    await showOfficeMessageUrgencyDetail(
      context,
      office,
      sourceRoom,
      str(value['id']),
    );
    if (current && office.connected) _load();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: SafeArea(
      child: Column(
        children: [
          _urgencyHeader(
            '会话加急',
            onRefresh: current && office.connected && !_busy ? _load : null,
            onClose: () => Navigator.pop(context),
          ),
          const Divider(height: 1),
          Expanded(
            child: !current
                ? _expiredUrgency
                : Column(
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            for (final tab in [
                              ('inbox', '发给我的'),
                              ('sent', '我发起的'),
                              ('all', '全部相关'),
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(tab.$2),
                                  selected: _box == tab.$1,
                                  onSelected: _busy
                                      ? null
                                      : (_) {
                                          setState(() {
                                            _box = tab.$1;
                                            _items = [];
                                            _before = null;
                                          });
                                          _load();
                                        },
                                ),
                              ),
                          ],
                        ),
                      ),
                      CheckboxListTile(
                        dense: true,
                        title: const Text('仅看待确认'),
                        value: _pendingOnly,
                        onChanged: _busy
                            ? null
                            : (value) {
                                setState(() {
                                  _pendingOnly = value == true;
                                  _items = [];
                                  _before = null;
                                });
                                _load();
                              },
                      ),
                      if (!office.connected) const Text('当前离线，重新连接后可以刷新。'),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: _urgencyError(_error),
                      ),
                      if (_error != null)
                        TextButton(
                          onPressed: _busy || !office.connected ? null : _load,
                          child: const Text('重新加载加急记录'),
                        ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          children: [
                            if (_busy)
                              const Center(child: CircularProgressIndicator()),
                            if (!_busy && _items.isEmpty && _error == null)
                              const Padding(
                                padding: EdgeInsets.all(24),
                                child: Center(child: Text('当前没有相关加急')),
                              ),
                            for (final item in _items)
                              Card(
                                child: InkWell(
                                  key: ValueKey('urgency-item-${item['id']}'),
                                  onTap: _busy || !office.connected
                                      ? null
                                      : () => _open(item),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons
                                                  .notifications_active_outlined,
                                              size: 18,
                                              color: accentColor,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                _requestStatus(item),
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              clockText(
                                                item['created_at'],
                                                date: true,
                                                context: context,
                                              ),
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: mutedColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        _urgencySource(item, compact: true),
                                        const SizedBox(height: 8),
                                        Text(
                                          item['summary_scope'] == 'sender'
                                              ? '我发起 · ${(item['counts'] as Map)['acknowledged']}/${(item['counts'] as Map)['total']} 已确认'
                                              : '发给我 · 查看确认详情',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: mutedColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            if (_more)
                              TextButton(
                                key: const ValueKey('urgency-load-more'),
                                onPressed: _busy || !office.connected
                                    ? null
                                    : () => _load(more: true),
                                child: const Text('加载更多加急'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}
