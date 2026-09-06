import 'dart:convert';

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart' show friendlyError;
import 'office_emoji.dart';
import 'office_theme.dart';

/// Returns a freshly read {room_id, message} only for opening a marked message.
Future<Json?> showOfficePersonalMessages(
  BuildContext context,
  OfficeState state, {
  String? roomId,
  bool hidden = false,
}) {
  final panel = OfficePersonalMessages(
    state: state,
    roomId: roomId,
    hidden: hidden,
  );
  if (MediaQuery.sizeOf(context).width < 720) {
    return showModalBottomSheet<Json>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .88,
        child: panel,
      ),
    );
  }
  return showDialog<Json>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: 540,
        height: MediaQuery.sizeOf(context).height * .8,
        child: panel,
      ),
    ),
  );
}

class OfficePersonalMessages extends StatefulWidget {
  const OfficePersonalMessages({
    super.key,
    required this.state,
    this.roomId,
    this.hidden = false,
  });
  final OfficeState state;
  final String? roomId;
  final bool hidden;

  @override
  State<OfficePersonalMessages> createState() => _OfficePersonalMessagesState();
}

class _OfficePersonalMessagesState extends State<OfficePersonalMessages> {
  late final (OfficeState, int, String, String) _identity;
  late final String? _roomId;
  late final bool _hidden;
  List<Json> _items = [];
  int? _before;
  int _intent = 0;
  bool _hasMore = false,
      _loading = false,
      _expired = false,
      _refreshQueued = false;
  String? _acting, _error, _status;
  OfficeState get s => widget.state;
  (OfficeState, int, String, String) get _currentIdentity =>
      (s, s.identityGeneration, s.endpoint, personId(s.me ?? {}));
  bool get _current =>
      !_expired && s.me != null && _identity == _currentIdentity;
  bool get _available =>
      _current && s.connected && !_loading && _acting == null;

  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    _roomId = widget.roomId;
    _hidden = widget.hidden;
    s.addListener(_changed);
    _load();
  }

  void _expire() {
    _expired = true;
    _intent++;
    _items = [];
    _before = null;
    _hasMore = _loading = false;
    _acting = _error = _status = null;
  }

  @override
  void didUpdateWidget(covariant OfficePersonalMessages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state) ||
        widget.roomId != _roomId ||
        widget.hidden != _hidden) {
      _expire();
    }
  }

  @override
  void dispose() {
    _intent++;
    _identity.$1.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) {
      setState(_expire);
      return;
    }
    setState(() {});
    if (!_available || _refreshQueued) return;
    _refreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshQueued = false;
      if (mounted && _available) _load();
    });
  }

  String _key(Json item) =>
      '${item['room_id']}:${(item['message'] as Map)['id']}';

  List<Json> _validatedItems(dynamic raw) {
    if (raw is! List) throw const FormatException('消息清单格式无效');
    final result = <Json>[];
    for (final entry in raw) {
      if (entry is! Map ||
          entry['message'] is! Map ||
          str(entry['room_id']).isEmpty) {
        throw const FormatException('消息清单缺少来源信息');
      }
      final item = Json.from(jsonDecode(jsonEncode(entry)) as Map);
      final message = Json.from(item['message'] as Map);
      if (str(message['id']).isEmpty ||
          (_roomId != null && item['room_id'] != _roomId)) {
        throw const FormatException('消息清单来源范围不匹配');
      }
      if (_hidden) {
        // Never render content/history/attachments from a personal tombstone,
        // even if an unexpected response happens to include those fields.
        item['message'] = {
          for (final name in [
            'id',
            'seq',
            'at',
            'author_id',
            'author',
            'revision',
            'personal_preferences',
          ])
            if (message.containsKey(name)) name: message[name],
          'hidden': true,
          'content': '',
        };
      } else if (message['hidden'] == true) {
        continue;
      } else if (message['retracted_at'] != null) {
        item['message'] = {
          for (final name in [
            'id',
            'seq',
            'at',
            'author_id',
            'author',
            'revision',
            'retracted_at',
            'personal_preferences',
          ])
            if (message.containsKey(name)) name: message[name],
          'content': '',
        };
      }
      result.add(item);
    }
    return result;
  }

  Future<bool> _load({bool more = false, bool afterMutation = false}) async {
    if (!_current ||
        !s.connected ||
        _loading ||
        (_acting != null && !afterMutation)) {
      return false;
    }
    if (more && (!_hasMore || _before == null)) return false;
    final intent = ++_intent;
    final target = more ? 50 : _items.length.clamp(50, 1000000);
    var before = more ? _before : null;
    final collected = <Json>[];
    var hasMore = false;
    int? next;
    setState(() {
      _loading = true;
      _error = null;
      _status = null;
    });
    try {
      do {
        final query = Uri(
          queryParameters: {
            'limit': '50',
            'room_id': ?_roomId,
            if (before != null) 'before': '$before',
          },
        ).query;
        final result = await s.officeRequest(
          '/${_hidden ? 'hidden-messages' : 'message-marks'}?$query',
        );
        if (!mounted || !_current || intent != _intent) return false;
        collected.addAll(_validatedItems(result['items']));
        hasMore = result['has_more'] == true;
        next = (result['next_before'] as num?)?.toInt();
        if (hasMore &&
            (next == null || next < 1 || (before != null && next >= before))) {
          throw const FormatException('消息分页未前进，请刷新后重试');
        }
        before = next;
      } while (!more && hasMore && collected.length < target);
      final unique = <String, Json>{};
      if (more) {
        for (final item in _items) {
          unique[_key(item)] = item;
        }
      }
      for (final item in collected) {
        unique[_key(item)] = item;
      }
      setState(() {
        _items = unique.values.toList();
        _hasMore = hasMore;
        _before = next;
      });
      return true;
    } catch (error) {
      if (mounted && _current && intent == _intent) {
        setState(() {
          _error = friendlyError(error);
          if (error is OfficeException && [401, 403].contains(error.status)) {
            _items = [];
            _hasMore = false;
          }
        });
      }
      return false;
    } finally {
      if (mounted && intent == _intent) setState(() => _loading = false);
    }
  }

  Future<void> _change(Json item) async {
    if (!_available) return;
    final key = _key(item);
    final roomId = str(item['room_id']);
    final messageId = str((item['message'] as Map)['id']);
    setState(() {
      _acting = key;
      _error = _status = null;
    });
    try {
      await s.setMessagePersonal(
        roomId,
        messageId,
        hidden: _hidden ? false : null,
        marked: _hidden ? null : false,
      );
      if (!mounted || !_current) return;
      final refreshed = await _load(afterMutation: true);
      if (!mounted || !_current) return;
      setState(
        () => _status = refreshed
            ? _items.any((item) => _key(item) == key)
                  ? '操作已提交，列表尚未反映变化，请刷新核对。'
                  : _hidden
                  ? '已恢复消息'
                  : '已取消标记'
            : _hidden
            ? '已恢复消息，列表刷新失败，请重试刷新。'
            : '已取消标记，列表刷新失败，请重试刷新。',
      );
    } catch (error) {
      if (mounted && _current) {
        setState(() {
          _error = friendlyError(error);
          if (error is OfficeException && [401, 403].contains(error.status)) {
            _items.removeWhere((item) => _key(item) == key);
          }
        });
      }
    } finally {
      if (mounted && _current) setState(() => _acting = null);
    }
  }

  Future<void> _open(Json item) async {
    if (!_available || _hidden) return;
    final key = _key(item);
    final roomId = str(item['room_id']);
    final messageId = str((item['message'] as Map)['id']);
    setState(() {
      _acting = key;
      _error = _status = null;
    });
    try {
      final result = await s.officeRequest(
        '/rooms/${Uri.encodeComponent(roomId)}/messages/${Uri.encodeComponent(messageId)}',
      );
      if (!mounted || !_current) return;
      final message = result['message'];
      if (message is! Map ||
          str(message['id']) != messageId ||
          (message['room_id'] != null && message['room_id'] != roomId)) {
        throw const FormatException('来源消息校验失败');
      }
      if (message['hidden'] == true) {
        await _load(afterMutation: true);
        if (mounted && _current) {
          setState(() => _error = '消息已从你的聊天中删除，可在已删除消息中恢复。');
        }
        return;
      }
      final selected = Json.from(message);
      if (selected['retracted_at'] != null) {
        selected.remove('history');
        selected['content'] = '';
        selected['attachments'] = <Json>[];
      }
      Navigator.of(context).pop({'room_id': roomId, 'message': selected});
    } catch (error) {
      if (mounted && _current) {
        setState(() {
          _error = friendlyError(error);
          if (error is OfficeException && [401, 403].contains(error.status)) {
            _items.removeWhere((item) => _key(item) == key);
          }
        });
      }
    } finally {
      if (mounted && _current) setState(() => _acting = null);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _hidden ? '已删除消息' : '标记的消息',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('personal-messages-refresh'),
              tooltip: '刷新',
              onPressed: _available ? () => _load() : null,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              key: const ValueKey('personal-messages-close'),
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      if (_current && _hidden)
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 12, 18, 4),
          child: Text(
            '恢复后可在原会话再次查看。',
            style: TextStyle(color: mutedColor, fontSize: 12),
          ),
        ),
      if (_current && !s.connected)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('当前离线，连接恢复后可以继续。'),
        ),
      if (_current && _error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error!,
                  key: const ValueKey('personal-messages-error'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
              TextButton(
                onPressed: _available ? () => _load() : null,
                child: const Text('重试刷新'),
              ),
            ],
          ),
        ),
      if (_current && _status != null)
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            _status!,
            key: const ValueKey('personal-messages-status'),
            style: const TextStyle(color: accentColor),
          ),
        ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: !_current
            ? const Center(child: Text('工作身份或查看范围已变化，请关闭后重新打开。'))
            : _items.isEmpty && !_loading
            ? Center(
                child: Text(
                  _hidden ? '暂无已删除消息' : '暂无标记消息',
                  style: const TextStyle(color: mutedColor),
                ),
              )
            : ListView.builder(
                key: const ValueKey('personal-messages-list'),
                padding: const EdgeInsets.all(14),
                itemCount: _items.length + (_hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _items.length) {
                    return Center(
                      child: TextButton(
                        key: const ValueKey('personal-messages-more'),
                        onPressed: _available ? () => _load(more: true) : null,
                        child: const Text('加载更多'),
                      ),
                    );
                  }
                  final item = _items[index],
                      message = Json.from(_items[index]['message'] as Map);
                  final key = _key(item);
                  final author = Json.from(message['author'] as Map? ?? {});
                  return Card(
                    key: ValueKey('personal-message-$key'),
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${str(item['room_name'], '来源会话')} · ${officeDisplayName(author)}${author['kind'] == 'agent' ? ' · Agent' : ''}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            clockText(
                              message['at'],
                              date: true,
                              context: context,
                            ),
                            style: const TextStyle(
                              fontSize: 11,
                              color: mutedColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_hidden)
                            const Text(
                              '消息已从你的聊天中删除',
                              style: TextStyle(color: mutedColor),
                            )
                          else if (message['retracted_at'] != null)
                            const Text(
                              '这条消息已撤回',
                              style: TextStyle(color: mutedColor),
                            )
                          else
                            OfficeEmojiText(
                              content: str(message['content']),
                              selectable: false,
                            ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (!_hidden)
                                TextButton(
                                  key: ValueKey('personal-message-open-$key'),
                                  onPressed: _available
                                      ? () => _open(item)
                                      : null,
                                  child: const Text('打开原消息'),
                                ),
                              TextButton(
                                key: ValueKey('personal-message-change-$key'),
                                onPressed: _available
                                    ? () => _change(item)
                                    : null,
                                child: Text(
                                  _acting == key
                                      ? '正在处理…'
                                      : _hidden
                                      ? '恢复消息'
                                      : '取消标记',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}
