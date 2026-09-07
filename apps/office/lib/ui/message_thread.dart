import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'attachments.dart';
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'office_emoji.dart';

Future<void> showOfficeMessageThread(
  BuildContext context,
  OfficeState state,
  String roomId,
  Json rootMessage, {
  bool createTopic = false,
}) {
  final panel = OfficeMessageThread(
    state: state,
    roomId: roomId,
    rootMessage: rootMessage,
    createTopic: createTopic,
  );
  if (MediaQuery.sizeOf(context).width < 760) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .88,
          child: panel,
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      alignment: Alignment.centerRight,
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 480,
        height: MediaQuery.sizeOf(context).height - 32,
        child: panel,
      ),
    ),
  );
}

class OfficeMessageThread extends StatefulWidget {
  const OfficeMessageThread({
    super.key,
    required this.state,
    required this.roomId,
    required this.rootMessage,
    this.createTopic = false,
  });
  final OfficeState state;
  final String roomId;
  final Json rootMessage;
  final bool createTopic;
  @override
  State<OfficeMessageThread> createState() => _OfficeMessageThreadState();
}

class _OfficeMessageThreadState extends State<OfficeMessageThread> {
  final _input = TextEditingController();
  late final (OfficeState, int, String, String) _identity;
  late final String _rootId, _roomId;
  Json? _root, _replyTo;
  Json? _topic;
  List<Json> _messages = [];
  int _cursor = 0, _total = 0, _intent = 0;
  bool _busy = false, _sending = false, _hasMore = false, _expired = false;
  String? _loadError, _sendError;
  bool _refreshQueued = false;
  bool _reopenRequired = false;
  OfficeState get s => widget.state;
  (OfficeState, int, String, String) get _currentIdentity =>
      (s, s.identityGeneration, s.endpoint, personId(s.me ?? {}));
  bool get _current =>
      !_expired && s.me != null && _identity == _currentIdentity;
  bool get _writable =>
      _current && s.connected && !_busy && !_sending && _root != null;

  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    _rootId = str(widget.rootMessage['id']);
    _roomId = widget.roomId;
    s.addListener(_changed);
    _load();
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) {
      _expired = true;
      _intent++;
      _input.clear();
      _root = _replyTo = null;
      _topic = null;
      _messages = [];
      _loadError = _sendError = null;
      setState(() {});
      return;
    }
    setState(() {});
    if (!s.connected || _busy || _sending || _root == null || _refreshQueued) {
      return;
    }
    _refreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshQueued = false;
      if (mounted && _current && s.connected && !_sending) _load();
    });
  }

  @override
  void didUpdateWidget(covariant OfficeMessageThread oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) _changed();
  }

  @override
  void dispose() {
    _intent++;
    _identity.$1.removeListener(_changed);
    _input.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false, int? through}) async {
    if (!_current || _busy || !s.connected || _reopenRequired) return;
    final intent = ++_intent;
    final target = through ?? _cursor;
    var after = more ? _cursor : 0;
    final collected = <Json>[];
    setState(() {
      _busy = true;
      _loadError = null;
    });
    try {
      if (widget.createTopic && _topic == null) {
        final topic = await s.createMessageTopic(_roomId, widget.rootMessage);
        if (!mounted || !_current || intent != _intent) return;
        if (topic['room_id'] != _roomId ||
            topic['root_message_id'] != _rootId ||
            str(topic['id']).isEmpty) {
          throw OfficeException(502, '话题响应不完整，请重试');
        }
        _topic = topic;
      }
      if (widget.createTopic) {
        final detail = await s.officeRequest(
          '/rooms/${Uri.encodeComponent(_roomId)}/topics/${Uri.encodeComponent(str(_topic!['id']))}',
        );
        if (!mounted || !_current || intent != _intent) return;
        final topic = detail['topic'];
        if (topic is! Map ||
            topic['id'] != _topic!['id'] ||
            topic['room_id'] != _roomId ||
            topic['root_message_id'] != _rootId) {
          throw OfficeException(502, '话题响应不完整，请重试');
        }
      }
      late Json result;
      do {
        result = await s.officeRequest(
          '/rooms/${Uri.encodeComponent(_roomId)}/messages/${Uri.encodeComponent(_rootId)}/thread?after=$after&limit=50',
        );
        if (!mounted || !_current || intent != _intent) return;
        if (widget.createTopic) {
          final root = result['root_message'];
          if (root is Map &&
              (root['hidden'] == true || root['retracted_at'] != null)) {
            throw OfficeException(409, '原消息已隐藏或撤回，当前话题不可用');
          }
        }
        collected.addAll(maps(result['messages']));
        final next = (result['after_cursor'] as num?)?.toInt() ?? after;
        if (result['has_more'] == true && next <= after) {
          throw StateError('话题分页未前进，请重新加载');
        }
        after = next;
      } while (!more && result['has_more'] == true && after < target);
      setState(() {
        _root = Json.from(result['root_message'] as Map);
        final byId = <String, Json>{
          if (more)
            for (final message in _messages) str(message['id']): message,
          for (final message in collected) str(message['id']): message,
        };
        _messages = byId.values.toList()
          ..sort(
            (a, b) =>
                ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0),
          );
        _cursor = after;
        _hasMore = result['has_more'] == true;
        _total = (result['total_replies'] as num?)?.toInt() ?? _messages.length;
        if (_replyTo != null) {
          _replyTo = _messages
              .where((message) => message['id'] == _replyTo!['id'])
              .firstOrNull;
        }
      });
    } catch (error) {
      if (mounted && _current && intent == _intent) {
        setState(() {
          _reopenRequired =
              widget.createTopic &&
              _topic == null &&
              error is OfficeException &&
              error.code == 'conflict';
          _loadError = _reopenRequired
              ? '原消息已变化，请关闭后重新打开话题。'
              : friendlyError(error);
          if (error is OfficeException &&
              ([401, 403, 404].contains(error.status) ||
                  widget.createTopic && error.status == 409)) {
            _root = _replyTo = null;
            _messages = [];
          }
        });
      }
    } finally {
      if (mounted && intent == _intent) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (!_writable || content.isEmpty) return;
    final draft = _input.text;
    final replyId = str(_replyTo?['id'], _rootId);
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      final sent = await s.send(
        content,
        sourceRoomId: _roomId,
        replyTo: replyId,
      );
      if (!mounted || !_current) return;
      if (_input.text == draft) _input.clear();
      setState(() {
        _replyTo = null;
        final byId = {
          for (final message in _messages) str(message['id']): message,
          str(sent['id']): sent,
        };
        _messages = byId.values.toList()
          ..sort(
            (a, b) =>
                ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0),
          );
      });
      await _load(through: (sent['seq'] as num?)?.toInt());
    } catch (error) {
      if (mounted && _current) {
        setState(() => _sendError = friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _message(Json message, {bool root = false}) {
    final author = Json.from(message['author'] as Map? ?? {});
    final retracted = message['retracted_at'] != null;
    return Container(
      key: ValueKey('thread-message-${message['id']}'),
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: root ? selectedColor : const Color(0xfff7f8fa),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PersonAvatar(
                name: officeDisplayName(author),
                agent: author['kind'] == 'agent',
                size: 28,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  officeDisplayName(author),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
              if (author['kind'] == 'agent')
                const Text(
                  'Agent',
                  style: TextStyle(fontSize: 10, color: mutedColor),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (root)
            const Text(
              '话题原消息',
              style: TextStyle(fontSize: 10, color: mutedColor),
            ),
          if (retracted)
            const Text('这条消息已撤回', style: TextStyle(color: mutedColor))
          else ...[
            OfficeEmojiText(
              content: str(message['content']),
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
            for (final attachment in maps(message['attachments']))
              MessageAttachment(state: s, attachment: attachment),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  fullOfficeTime(message['at'], context: context),
                  style: const TextStyle(fontSize: 10, color: mutedColor),
                ),
              ),
              if (!retracted)
                TextButton(
                  onPressed: _writable
                      ? () => setState(() => _replyTo = root ? null : message)
                      : null,
                  child: const Text('回复', style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ],
      ),
    );
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
                    '话题',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_current)
                  IconButton(
                    tooltip: '刷新话题',
                    onPressed: _busy || !s.connected || _reopenRequired
                        ? null
                        : _load,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                IconButton(
                  tooltip: '关闭话题',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (!_current)
            const Expanded(child: Center(child: Text('工作身份已变化，请关闭后重新打开话题。')))
          else ...[
            Expanded(
              child: ListView(
                key: const ValueKey('thread-messages'),
                padding: const EdgeInsets.all(16),
                children: [
                  if (!s.connected) const Text('连接已中断，回复草稿已保留。'),
                  BusinessError(_loadError),
                  if (_loadError != null && !_reopenRequired)
                    TextButton(
                      onPressed: _busy || !s.connected ? null : _load,
                      child: const Text('重新加载话题'),
                    ),
                  if (_root != null) _message(_root!, root: true),
                  if (_root != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '$_total 条回复',
                        style: const TextStyle(color: mutedColor, fontSize: 12),
                      ),
                    ),
                  for (final message in _messages) _message(message),
                  if (_root != null && _messages.isEmpty && !_busy)
                    const Text('还没有回复，一起继续这个话题。'),
                  if (_busy)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  if (_hasMore)
                    TextButton(
                      onPressed: _busy || !s.connected
                          ? null
                          : () => _load(more: true),
                      child: const Text('加载更多回复'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_replyTo != null)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '回复：${str(_replyTo!['content'])}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: mutedColor,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '改为回复原消息',
                          onPressed: _sending
                              ? null
                              : () => setState(() => _replyTo = null),
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                  BusinessError(_sendError),
                  TextField(
                    key: const ValueKey('thread-reply-input'),
                    controller: _input,
                    enabled: !_sending,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(hintText: '在话题中回复'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _writable && _input.text.trim().isNotEmpty
                          ? _send
                          : null,
                      child: Text(_sending ? '发送中…' : '发送回复'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
