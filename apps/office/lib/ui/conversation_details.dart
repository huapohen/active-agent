import 'dart:async';

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_theme.dart';
import 'office_dialogs.dart';
import 'message_original.dart';

Future<void> showOfficeMessageReaders(
  BuildContext context,
  OfficeState state,
  Json message,
) => showDialog<void>(
  context: context,
  builder: (_) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final peers = maps(state.detail?['members'])
          .where((p) => personId(p) != str(message['author_id']))
          .toList();
      final seq = (message['seq'] as num?)?.toInt() ?? 1;
      final read = peers
          .where((p) => ((p['read_seq'] as num?)?.toInt() ?? 0) >= seq)
          .toList();
      final unread = peers.where((p) => !read.contains(p)).toList();
      return DefaultTabController(
        length: 2,
        child: AlertDialog(
          title: const Text('消息阅读状态'),
          content: SizedBox(
            width: 400,
            height: 380,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(text: '已读 ${read.length}'),
                    Tab(text: '未读 ${unread.length}'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      for (final group in [read, unread])
                        group.isEmpty
                            ? const Center(child: Text('暂无成员'))
                            : ListView(
                                children: [
                                  for (final p in group)
                                    ListTile(
                                      leading: PersonAvatar(
                                        name: officeDisplayName(p),
                                        agent: p['kind'] == 'agent',
                                        size: 32,
                                      ),
                                      title: Text(officeDisplayName(p)),
                                      subtitle: Text(
                                        p['kind'] == 'agent'
                                            ? 'Agent 同事'
                                            : '成员',
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    },
  ),
);

Future<String?> showOfficeForwardPicker(
  BuildContext context,
  List<Json> rooms,
  Json message,
) => showDialog<String>(
  context: context,
  builder: (_) => OfficeForwardPicker(rooms: rooms, message: message),
);

class OfficeForwardPicker extends StatefulWidget {
  const OfficeForwardPicker({
    super.key,
    required this.rooms,
    required this.message,
  });
  final List<Json> rooms;
  final Json message;
  @override
  State<OfficeForwardPicker> createState() => _OfficeForwardPickerState();
}

class _OfficeForwardPickerState extends State<OfficeForwardPicker> {
  String _query = '';
  String? _selected;
  @override
  Widget build(BuildContext context) {
    final rooms = widget.rooms
        .where(
          (r) => str(r['name']).toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    final selected = widget.rooms
        .where((r) => r['id'] == _selected)
        .firstOrNull;
    return AlertDialog(
      title: const Text('转发消息'),
      content: SizedBox(
        width: 440,
        height: 430,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              str(widget.message['content'], '附件消息'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: mutedColor),
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                hintText: '搜索人、Agent 或群聊',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rooms.isEmpty
                  ? const Center(child: Text('没有匹配的会话'))
                  : ListView(
                      children: [
                        for (final r in rooms)
                          ListTile(
                            leading: PersonAvatar(
                              name: str(r['name']),
                              group: r['kind'] != 'direct',
                              size: 32,
                            ),
                            title: Text(str(r['name'])),
                            trailing: Icon(
                              _selected == r['id']
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              color: _selected == r['id']
                                  ? accentColor
                                  : mutedColor,
                            ),
                            onTap: () =>
                                setState(() => _selected = str(r['id'])),
                          ),
                      ],
                    ),
            ),
            if (selected != null)
              Text(
                '发送到：${str(selected['name'])}',
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: selected == null
              ? null
              : () => Navigator.pop(context, _selected),
          child: const Text('确认转发'),
        ),
      ],
    );
  }
}

Future<void> showOfficeRoomSearch(
  BuildContext context,
  OfficeState state,
  String roomId,
) => showDialog<void>(
  context: context,
  builder: (_) => OfficeRoomSearch(state: state, roomId: roomId),
);

class OfficeRoomSearch extends StatefulWidget {
  const OfficeRoomSearch({
    super.key,
    required this.state,
    required this.roomId,
  });
  final OfficeState state;
  final String roomId;
  @override
  State<OfficeRoomSearch> createState() => _OfficeRoomSearchState();
}

class _OfficeRoomSearchState extends State<OfficeRoomSearch> {
  late final String _identity;
  String get _currentIdentity =>
      '${widget.state.endpoint}:${personId(widget.state.me ?? {})}';
  bool get _validIdentity => _identity == _currentIdentity;
  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    widget.state.addListener(_identityChanged);
  }

  void _identityChanged() {
    if (!_validIdentity && mounted) {
      _timer?.cancel();
      _intent++;
      setState(() {
        _results = [];
        _busy = false;
        _error = '工作身份已切换，请关闭后重新搜索';
      });
    }
  }

  Timer? _timer;
  int _intent = 0;
  bool _busy = false, _truncated = false;
  String _query = '';
  String? _error;
  List<Json> _results = [];
  @override
  void dispose() {
    widget.state.removeListener(_identityChanged);
    _timer?.cancel();
    _intent++;
    super.dispose();
  }

  void _search(String query) {
    if (!_validIdentity) return;
    final intent = ++_intent;
    _timer?.cancel();
    setState(() {
      _query = query.trim();
      _error = null;
      _results = [];
      _busy = _query.isNotEmpty;
      _truncated = false;
    });
    if (_query.isEmpty) return;
    final params = Uri(
      queryParameters: {
        'q': _query,
        'type': 'message',
        'room_id': widget.roomId,
      },
    ).query;
    _timer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final result = await widget.state.officeRequest('/search?$params');
        if (mounted && intent == _intent) {
          setState(() {
            _results = maps(result['results']);
            _truncated = result['truncated'] == true;
          });
        }
      } catch (e) {
        if (mounted && intent == _intent) {
          setState(() => _error = friendlyError(e));
        }
      } finally {
        if (mounted && intent == _intent) setState(() => _busy = false);
      }
    });
  }

  Future<void> _open(Json item) async {
    if (!_validIdentity) return;
    await showOfficeMessageOriginal(
      context,
      widget.state,
      widget.roomId,
      str(item['id']),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('查找聊天内容'),
    content: SizedBox(
      width: 520,
      height: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(
              hintText: '搜索本会话全部历史消息',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: _search,
          ),
          BusinessError(_error),
          if (_truncated)
            const Text(
              '结果较多，请输入更具体的关键词。',
              style: TextStyle(color: mutedColor, fontSize: 12),
            ),
          Expanded(
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                ? Center(
                    child: Text(_query.isEmpty ? '输入关键词查找历史消息' : '没有匹配的消息'),
                  )
                : ListView(
                    children: [
                      for (final item in _results)
                        ListTile(
                          title: Text(
                            str(item['snippet']),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            fullOfficeTime(item['at'], context: context),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(item),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
