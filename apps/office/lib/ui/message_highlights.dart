import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart' show friendlyError;
import 'office_emoji.dart';
import 'office_theme.dart';

/// Top-of-chat highlights have their own revision and personal collapse state.
/// They do not read or mutate the existing Pin collection.
class _HighlightsModel extends ChangeNotifier {
  _HighlightsModel(this.state, this.roomId) {
    _identity = _currentIdentity;
    state.addListener(_changed);
    load();
  }
  final OfficeState state;
  final String roomId;
  late final (int, String, String) _identity;
  bool _expired = false, _disposed = false, _queued = false;
  int _intent = 0;
  Json? value;
  String? error;
  bool busy = false, needsRefresh = false, accessDenied = false;
  (int, String, String) get _currentIdentity =>
      (state.identityGeneration, state.endpoint, personId(state.me ?? {}));
  bool get current =>
      !_expired &&
      !_disposed &&
      state.me != null &&
      _identity == _currentIdentity;
  bool get available =>
      current && state.connected && !busy && !needsRefresh && value != null;
  List<Json> get items => maps(value?['items']);
  bool get collapsed => value?['collapsed'] == true;
  bool get canSet =>
      available && (value?['permissions'] as Map?)?['can_set'] == true;
  bool get canClear =>
      available && (value?['permissions'] as Map?)?['can_clear'] == true;
  String get path => '/rooms/${Uri.encodeComponent(roomId)}/highlights';

  void expire() {
    _expired = true;
    _intent++;
    value = null;
    error = null;
    busy = false;
    notifyListeners();
  }

  void _changed() {
    if (_disposed) return;
    if (!current) {
      expire();
      return;
    }
    notifyListeners();
    if (!state.connected || busy || _queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (current && state.connected && !busy) load();
    });
  }

  Json _validated(Json data) {
    if (data['revision'] is! num ||
        data['items'] is! List ||
        data['permissions'] is! Map) {
      throw const FormatException('顶部置顶状态不完整，请重新加载');
    }
    final items = <Json>[];
    for (final item in maps(data['items'])) {
      final source = item['message'];
      if (source is! Map ||
          str(item['message_id']).isEmpty ||
          source['id'] != item['message_id']) {
        throw const FormatException('顶部置顶消息来源不匹配');
      }
      if (source['hidden'] == true) continue;
      final message = Json.from(source);
      if (item['source_status'] == 'retracted' ||
          message['retracted_at'] != null) {
        message.remove('attachments');
        message.remove('history');
        message['content'] = '';
      }
      items.add({...item, 'message': message});
    }
    return {...data, 'items': items};
  }

  Future<void> load() async {
    if (!current || !state.connected || busy) return;
    final intent = ++_intent;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await state.officeRequest(path);
      if (!current || intent != _intent) return;
      value = _validated(result);
      needsRefresh = false;
      accessDenied = false;
    } catch (e) {
      if (current && intent == _intent) {
        value = null;
        accessDenied =
            e is OfficeException && (e.status == 403 || e.status == 404);
        error = friendlyError(e);
      }
    } finally {
      if (current && intent == _intent) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> mutate(Json data, {bool preferences = false}) async {
    if (!available) return false;
    if (!preferences && (data['message_id'] == null ? !canClear : !canSet)) {
      return false;
    }
    final intent = ++_intent;
    final payload = {'base_revision': value!['revision'], ...data};
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await state.officeRequest(
        '$path${preferences ? '/preferences' : ''}',
        method: 'PATCH',
        data: payload,
      );
      if (!current || intent != _intent) return false;
      value = _validated(result);
      return true;
    } catch (e) {
      if (current && intent == _intent) {
        needsRefresh = true;
        if (e is OfficeException && (e.status == 403 || e.status == 404)) {
          accessDenied = true;
          value = null;
        }
        error = e is OfficeException && e.status == 409
            ? '顶部置顶已被其他成员更新，请先刷新再操作。'
            : '${friendlyError(e)}。请刷新确认当前顶部置顶状态。';
      }
      return false;
    } finally {
      if (current && intent == _intent) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _intent++;
    state.removeListener(_changed);
    super.dispose();
  }
}

/// Inline, independently refreshed banner. Give this widget a room-scoped key
/// when switching rooms; a retained widget never adopts another source scope.
class OfficeMessageHighlightsBanner extends StatefulWidget {
  const OfficeMessageHighlightsBanner({
    super.key,
    required this.state,
    required this.roomId,
    required this.onOpenMessage,
    this.onManage,
  });
  final OfficeState state;
  final String roomId;
  final ValueChanged<String> onOpenMessage;
  final VoidCallback? onManage;
  @override
  State<OfficeMessageHighlightsBanner> createState() =>
      _OfficeMessageHighlightsBannerState();
}

class _OfficeMessageHighlightsBannerState
    extends State<OfficeMessageHighlightsBanner> {
  late final _HighlightsModel _model;
  @override
  void initState() {
    super.initState();
    _model = _HighlightsModel(widget.state, widget.roomId);
  }

  @override
  void didUpdateWidget(covariant OfficeMessageHighlightsBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state) ||
        oldWidget.roomId != widget.roomId) {
      _model.expire();
    }
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _manage() async {
    if (!_model.current) return;
    if (widget.onManage != null) {
      widget.onManage!();
      return;
    }
    await showOfficeMessageHighlight(
      context,
      widget.state,
      widget.roomId,
      onOpenMessage: widget.onOpenMessage,
    );
    if (mounted && _model.current) _model.load();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _model,
    builder: (context, _) {
      if (!_model.current) return const SizedBox.shrink();
      if (_model.value == null) {
        if (_model.error == null) return const SizedBox.shrink();
        return _highlightNotice(
          _model.error!,
          onRetry: _model.busy || !widget.state.connected ? null : _model.load,
        );
      }
      if (_model.items.isEmpty) return const SizedBox.shrink();
      return Material(
        key: const ValueKey('message-highlights-banner'),
        color: const Color(0xfff4f7ff),
        child: Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: borderColor)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: 12),
                  const Icon(
                    Icons.vertical_align_top,
                    size: 18,
                    color: accentColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '置顶消息${_model.items.length > 1 ? ' · ${_model.items.length}' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!widget.state.connected)
                    const Text(
                      '离线',
                      style: TextStyle(fontSize: 10, color: mutedColor),
                    ),
                  if (_model.busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  IconButton(
                    tooltip: '管理顶部置顶',
                    onPressed: _model.current ? _manage : null,
                    icon: const Icon(Icons.more_horiz, size: 18),
                  ),
                  IconButton(
                    key: const ValueKey('message-highlights-collapse'),
                    tooltip: _model.collapsed ? '展开置顶消息' : '仅为我收起置顶消息',
                    onPressed: _model.available
                        ? () => _model.mutate({
                            'collapsed': !_model.collapsed,
                          }, preferences: true)
                        : null,
                    icon: Icon(
                      _model.collapsed
                          ? Icons.keyboard_arrow_down
                          : Icons.close,
                      size: 18,
                    ),
                  ),
                ],
              ),
              if (!_model.collapsed)
                for (final item in _model.items)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(38, 0, 12, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _highlightPreview(item, compact: true)),
                        TextButton(
                          key: ValueKey('highlight-open-${item['message_id']}'),
                          onPressed: _model.available
                              ? () => widget.onOpenMessage(
                                  str(item['message_id']),
                                )
                              : null,
                          child: const Text(
                            '查看',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
              if (_model.error != null)
                _highlightNotice(
                  _model.error!,
                  onRetry: _model.busy || !widget.state.connected
                      ? null
                      : _model.load,
                ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _highlightNotice(String text, {VoidCallback? onRetry}) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  child: Row(
    children: [
      Expanded(
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, color: Colors.redAccent),
        ),
      ),
      TextButton(onPressed: onRetry, child: const Text('刷新')),
    ],
  ),
);

Widget _highlightPreview(Json item, {bool compact = false}) {
  final message = Json.from(item['message'] as Map);
  final withdrawn =
      item['source_status'] == 'retracted' || message['retracted_at'] != null;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (withdrawn)
        const Text(
          '这条置顶消息已撤回',
          style: TextStyle(fontSize: 12, color: mutedColor),
        )
      else if (compact)
        DefaultTextStyle.merge(
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          child: OfficeEmojiText(
            content: str(message['content'], '附件消息').replaceAll('\n', ' '),
            selectable: false,
            style: const TextStyle(fontSize: 12),
          ),
        )
      else
        OfficeEmojiText(
          content: str(message['content'], '附件消息'),
          selectable: false,
        ),
      if (item['source_status'] == 'updated')
        const Text(
          '消息内容已更新',
          style: TextStyle(fontSize: 10, color: mutedColor),
        ),
    ],
  );
}

/// Opens current top-of-chat state, or previews a message before replacing it.
/// Returns true only after a confirmed successful shared top-state mutation.
Future<bool?> showOfficeMessageHighlight(
  BuildContext context,
  OfficeState state,
  String roomId, {
  Json? message,
  ValueChanged<String>? onOpenMessage,
}) {
  final panel = OfficeMessageHighlights(
    state: state,
    roomId: roomId,
    message: message,
    onOpenMessage: onOpenMessage,
  );
  if (MediaQuery.sizeOf(context).width < 720) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: panel,
      ),
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 500,
        height: MediaQuery.sizeOf(context).height * .7,
        child: panel,
      ),
    ),
  );
}

class OfficeMessageHighlights extends StatefulWidget {
  const OfficeMessageHighlights({
    super.key,
    required this.state,
    required this.roomId,
    this.message,
    this.onOpenMessage,
  });
  final OfficeState state;
  final String roomId;
  final Json? message;
  final ValueChanged<String>? onOpenMessage;
  @override
  State<OfficeMessageHighlights> createState() =>
      _OfficeMessageHighlightsState();
}

class _OfficeMessageHighlightsState extends State<OfficeMessageHighlights> {
  late final _HighlightsModel _model;
  late final String? _messageId;
  Json? _source;
  String? _sourceError;
  bool _sourceBusy = false, _changed = false, _openingMessage = false;
  int _sourceIntent = 0;
  @override
  void initState() {
    super.initState();
    _messageId = widget.message == null ? null : str(widget.message!['id']);
    _model = _HighlightsModel(widget.state, widget.roomId)
      ..addListener(_modelChanged);
    if (_messageId != null) _loadSource();
  }

  void _modelChanged() {
    if (!mounted) return;
    if (!_model.current || _model.accessDenied) {
      _sourceIntent++;
      _source = null;
      _sourceError = null;
      _sourceBusy = false;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant OfficeMessageHighlights oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state) ||
        oldWidget.roomId != widget.roomId ||
        (widget.message == null ? null : str(widget.message!['id'])) !=
            _messageId) {
      _model.expire();
    }
  }

  @override
  void dispose() {
    _sourceIntent++;
    _model.removeListener(_modelChanged);
    _model.dispose();
    super.dispose();
  }

  Future<void> _loadSource() async {
    if (!_model.current ||
        _model.accessDenied ||
        !widget.state.connected ||
        _sourceBusy ||
        _messageId == null) {
      return;
    }
    final intent = ++_sourceIntent;
    setState(() {
      _sourceBusy = true;
      _sourceError = null;
      _source = null;
    });
    try {
      final result = await widget.state.officeRequest(
        '/rooms/${Uri.encodeComponent(_model.roomId)}/messages/${Uri.encodeComponent(_messageId)}',
      );
      if (!mounted || !_model.current || intent != _sourceIntent) return;
      final source = result['message'];
      if (source is! Map || source['id'] != _messageId) {
        throw const FormatException('来源消息不匹配');
      }
      if (source['revision'] is! num) {
        throw const FormatException('来源消息缺少版本');
      }
      if (source['hidden'] == true || source['retracted_at'] != null) {
        throw OfficeException(409, '来源消息已删除或撤回，不能置顶');
      }
      setState(() => _source = Json.from(source));
    } catch (e) {
      if (mounted && _model.current && intent == _sourceIntent) {
        setState(() => _sourceError = friendlyError(e));
      }
    } finally {
      if (mounted && intent == _sourceIntent) {
        setState(() => _sourceBusy = false);
      }
    }
  }

  Future<void> _set() async {
    final source = _source;
    if (source == null || !_model.canSet) return;
    if (await _model.mutate({
      'message_id': source['id'],
      'message_revision': source['revision'],
    })) {
      if (mounted && _model.current) {
        _changed = true;
        Navigator.pop(context, true);
      }
    }
  }

  Future<void> _clear() async {
    if (!_model.canClear) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消顶部置顶'),
        content: const Text('取消后，群成员聊天顶部将不再显示这条消息。Pin 集合中的内容不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消置顶'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_model.current) return;
    if (await _model.mutate({'message_id': null})) {
      if (mounted && _model.current) setState(() => _changed = true);
    }
  }

  void _openMessage(String messageId) {
    if (!mounted || !_model.available || _openingMessage) return;
    final onOpen = widget.onOpenMessage;
    if (onOpen == null || ModalRoute.of(context)?.isCurrent != true) return;
    _openingMessage = true;
    Navigator.pop(context, _changed);
    onOpen(messageId);
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 6, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '顶部置顶',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '刷新顶部置顶',
                  onPressed:
                      _model.busy || !widget.state.connected || !_model.current
                      ? null
                      : () async {
                          await _model.load();
                          if (mounted && _model.current) _loadSource();
                        },
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                IconButton(
                  tooltip: '关闭顶部置顶',
                  onPressed: () => Navigator.pop(context, _changed),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: !_model.current
                ? const Center(child: Text('工作身份或来源会话已变化，请关闭后重新打开。'))
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (!widget.state.connected)
                        const Text('连接已中断，暂时不能修改置顶。'),
                      if (_model.busy || _sourceBusy)
                        const Center(child: CircularProgressIndicator()),
                      if (_model.error != null)
                        _highlightNotice(
                          _model.error!,
                          onRetry: _model.busy || !widget.state.connected
                              ? null
                              : _model.load,
                        ),
                      if (_sourceError != null)
                        _highlightNotice(
                          _sourceError!,
                          onRetry: _sourceBusy || !widget.state.connected
                              ? null
                              : _loadSource,
                        ),
                      if (_messageId != null && _source != null) ...[
                        const Text(
                          '准备置顶的消息',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 10),
                        OfficeEmojiText(
                          content: str(_source!['content'], '附件消息'),
                          selectable: false,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _model.items.isEmpty
                              ? '置顶后，所有当前群成员都能在聊天顶部看到。'
                              : '当前顶部已有置顶消息；确认后将替换为这条消息。',
                          style: const TextStyle(
                            fontSize: 12,
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          key: const ValueKey('highlight-set'),
                          onPressed: _model.canSet && !_sourceBusy
                              ? _set
                              : null,
                          child: Text(
                            _model.items.isEmpty ? '置顶这条消息' : '替换当前置顶',
                          ),
                        ),
                        const Divider(height: 28),
                      ],
                      const Text(
                        '当前顶部置顶',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      if (_model.value != null && _model.items.isEmpty)
                        const Text('当前没有顶部置顶消息'),
                      for (final item in _model.items)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _highlightPreview(item),
                                const SizedBox(height: 8),
                                if (widget.onOpenMessage != null)
                                  TextButton(
                                    onPressed: _model.available
                                        ? () => _openMessage(
                                            str(item['message_id']),
                                          )
                                        : null,
                                    child: const Text('查看原消息'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      if (_model.items.isNotEmpty) ...[
                        TextButton(
                          key: const ValueKey('highlight-personal-collapse'),
                          onPressed: _model.available
                              ? () => _model.mutate({
                                  'collapsed': !_model.collapsed,
                                }, preferences: true)
                              : null,
                          child: Text(_model.collapsed ? '为我展开置顶' : '仅为我收起置顶'),
                        ),
                        if ((_model.value?['permissions']
                                as Map?)?['can_clear'] ==
                            true)
                          TextButton(
                            key: const ValueKey('highlight-clear'),
                            onPressed: _model.canClear ? _clear : null,
                            child: const Text('取消顶部置顶'),
                          ),
                      ],
                      if (_model.value != null &&
                          (_model.value!['permissions'] as Map)['can_set'] !=
                              true)
                        const Text(
                          '当前身份没有群内置顶管理权限。',
                          style: TextStyle(fontSize: 12, color: mutedColor),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}
