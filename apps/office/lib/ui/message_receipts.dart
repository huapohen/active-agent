import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeMessageReceiptIndicator extends StatelessWidget {
  const OfficeMessageReceiptIndicator({
    super.key,
    required this.message,
    required this.roomKind,
    required this.onOpen,
  });
  final Json message;
  final String roomKind;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final summary = message['receipt_summary'] as Map? ?? {};
    if (summary['basis'] == 'message_retracted' ||
        message['retracted_at'] != null) {
      return const SizedBox.shrink();
    }
    final known = summary['known'] == true;
    final read = (summary['read_count'] as num?)?.toInt() ?? 0;
    final eligible = (summary['eligible_count'] as num?)?.toInt() ?? 0;
    final label = !known
        ? '阅读状态未知'
        : eligible == 0
        ? '无接收成员'
        : roomKind == 'direct'
        ? (read > 0 ? '已读' : '未读')
        : '$read/$eligible 已读';
    return TextButton.icon(
      onPressed: onOpen,
      style: TextButton.styleFrom(
        foregroundColor: known && read > 0
            ? roomKind == 'direct'
                  ? const Color(0xffed727a)
                  : accentColor
            : mutedColor,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(
        !known
            ? Icons.help_outline
            : roomKind == 'direct'
            ? Icons.check
            : read > 0
            ? Icons.done_all
            : Icons.check,
        size: 13,
      ),
      label: Text(label, style: const TextStyle(fontSize: 10)),
    );
  }
}

Future<void> showOfficeMessageReceipts(
  BuildContext context,
  OfficeState state,
  String roomId,
  Json message,
) {
  final panel = OfficeMessageReceipts(
    state: state,
    roomId: roomId,
    messageId: str(message['id']),
  );
  if (MediaQuery.sizeOf(context).width < 760) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: panel,
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: SizedBox(
        width: 440,
        height: MediaQuery.sizeOf(context).height * .7,
        child: panel,
      ),
    ),
  );
}

class OfficeMessageReceipts extends StatefulWidget {
  const OfficeMessageReceipts({
    super.key,
    required this.state,
    required this.roomId,
    required this.messageId,
  });
  final OfficeState state;
  final String roomId, messageId;
  @override
  State<OfficeMessageReceipts> createState() => _OfficeMessageReceiptsState();
}

class _OfficeMessageReceiptsState extends State<OfficeMessageReceipts> {
  late final (OfficeState, int, String, String) _identity;
  late final String _roomId, _messageId;
  Json? _summary;
  List<Json> _readers = [];
  bool _busy = false, _expired = false;
  int _intent = 0;
  String? _error;
  bool _refreshQueued = false;
  OfficeState get s => widget.state;
  (OfficeState, int, String, String) get _currentIdentity =>
      (s, s.identityGeneration, s.endpoint, personId(s.me ?? {}));
  bool get _current =>
      !_expired && s.me != null && _identity == _currentIdentity;
  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    _roomId = widget.roomId;
    _messageId = widget.messageId;
    s.addListener(_changed);
    _load();
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) {
      _expired = true;
      _intent++;
      _summary = null;
      _readers = [];
      _error = null;
    }
    setState(() {});
    if (_current &&
        s.connected &&
        !_busy &&
        _summary != null &&
        !_refreshQueued) {
      _refreshQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshQueued = false;
        if (mounted && _current && s.connected) _load();
      });
    }
  }

  @override
  void didUpdateWidget(covariant OfficeMessageReceipts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) _changed();
  }

  @override
  void dispose() {
    _intent++;
    _identity.$1.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _busy || !s.connected) return;
    final intent = ++_intent;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await s.officeRequest(
        '/rooms/${Uri.encodeComponent(_roomId)}/messages/${Uri.encodeComponent(_messageId)}/readers',
      );
      if (!mounted || !_current || intent != _intent) return;
      setState(() {
        _summary = Json.from(result['receipt_summary'] as Map);
        _readers = maps(result['readers']);
      });
    } catch (error) {
      if (mounted && _current && intent == _intent) {
        setState(() {
          _error = friendlyError(error);
          _summary = null;
          _readers = [];
        });
      }
    } finally {
      if (mounted && intent == _intent) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '阅读状态',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_current)
                  IconButton(
                    tooltip: '刷新阅读状态',
                    onPressed: _busy || !s.connected ? null : _load,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                IconButton(
                  tooltip: '关闭阅读状态',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: !_current
                ? const Center(child: Text('工作身份已变化，请关闭后重新打开阅读状态。'))
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (!s.connected) const Text('连接已中断，重新连接后可以刷新。'),
                      BusinessError(_error),
                      if (_error != null)
                        TextButton(
                          onPressed: _busy || !s.connected ? null : _load,
                          child: const Text('重新加载阅读状态'),
                        ),
                      if (_busy)
                        const Center(child: CircularProgressIndicator()),
                      if (_summary != null) ...[
                        if (_summary!['known'] != true)
                          Text(
                            _summary!['basis'] == 'message_retracted'
                                ? '消息已撤回，不再展示阅读状态。'
                                : '阅读状态未知：这条历史消息没有发送时的接收成员记录，不能判定已读或未读。',
                          )
                        else ...[
                          Text(
                            '${_summary!['read_count']} 已读 · ${_summary!['unread_count']} 未读',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '依据发送时的接收成员与明确阅读确认。人和 Agent 使用相同规则。',
                            style: TextStyle(fontSize: 12, color: mutedColor),
                          ),
                          const SizedBox(height: 12),
                          if (_readers.isEmpty) const Text('没有接收成员'),
                          for (final reader in _readers)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: PersonAvatar(
                                name: str(reader['name']),
                                agent: reader['kind'] == 'agent',
                                size: 32,
                              ),
                              title: Text(
                                str(reader['name']),
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                [
                                  reader['kind'] == 'agent'
                                      ? 'Agent 同事'
                                      : '人类同事',
                                  if (reader['current_member'] == false)
                                    '已离开会话'
                                  else if (reader['same_membership'] == false)
                                    '已重新加入；按发送时身份统计',
                                  if (reader['acknowledged_at'] != null)
                                    '最近确认：${fullOfficeTime(reader['acknowledged_at'], context: context)}',
                                ].join(' · '),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: mutedColor,
                                ),
                              ),
                              trailing: Text(
                                reader['status'] == 'read' ? '已读' : '未读',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: reader['status'] == 'read'
                                      ? accentColor
                                      : mutedColor,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}
