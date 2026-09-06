import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_theme.dart';

Future<String?> showOfficeMessageEdit(
  BuildContext context,
  OfficeState state,
  Json message,
) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _MessageMutationDialog(state: state, message: message),
);

Future<bool?> confirmOfficeMessageRetraction(
  BuildContext context,
  OfficeState state,
  Json message,
) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _MessageMutationDialog(state: state, message: message, retract: true),
);

/// Returns a user decision only. The caller retains its captured source room
/// and original message revision when performing the actual API mutation.
class _MessageMutationDialog extends StatefulWidget {
  const _MessageMutationDialog({
    required this.state,
    required this.message,
    this.retract = false,
  });
  final OfficeState state;
  final Json message;
  final bool retract;
  @override
  State<_MessageMutationDialog> createState() => _MessageMutationDialogState();
}

class _MessageMutationDialogState extends State<_MessageMutationDialog> {
  late final String _identity, _roomId, _messageId, _authorId;
  late final TextEditingController _content;
  late final bool _hasAttachments;
  bool _expired = false, _retracted = false;
  String? _error;
  String get _identityKey =>
      '${widget.state.endpoint}|${personId(widget.state.me ?? {})}|${widget.state.connected}';
  bool get _valid =>
      !_expired && widget.state.connected && _identity == _identityKey;
  bool get _ownsMessage =>
      _authorId == personId(widget.state.me ?? {}) && _authorId.isNotEmpty;
  bool get _canSubmit => _valid && !_retracted && _ownsMessage;

  @override
  void initState() {
    super.initState();
    _identity = _identityKey;
    _roomId = str(widget.message['room_id'] ?? widget.state.selectedRoomId);
    _messageId = str(widget.message['id']);
    _authorId = str(
      widget.message['author_id'] ??
          (widget.message['author'] as Map?)?['id'] ??
          (widget.message['author'] as Map?)?['principal_id'],
    );
    _hasAttachments =
        (widget.message['attachment_ids'] as List? ?? []).isNotEmpty ||
        maps(widget.message['attachments']).isNotEmpty;
    _retracted = widget.message['retracted_at'] != null;
    _content = TextEditingController(text: str(widget.message['content']));
    _observe();
    widget.state.addListener(_changed);
  }

  void _observe() {
    if (!_valid) _expired = true;
    final detail = widget.state.detail;
    if (str((detail?['room'] as Map?)?['id']) == _roomId) {
      final latest = maps(detail?['messages'])
          .where((message) => str(message['id']) == _messageId)
          .firstOrNull;
      if (latest?['retracted_at'] != null) _retracted = true;
    }
    if (widget.message['retracted_at'] != null) _retracted = true;
    if (_expired || _retracted) {
      _content.clear();
      _error = null;
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(_observe);
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    _content.dispose();
    super.dispose();
  }

  void _submit() {
    // Recheck synchronously as well as reacting to state notifications.
    _observe();
    if (!_canSubmit) {
      setState(() {});
      return;
    }
    if (!widget.retract && _content.text.trim().isEmpty && !_hasAttachments) {
      setState(() => _error = '消息内容不能为空');
      return;
    }
    if (widget.retract) {
      Navigator.pop(context, true);
    } else {
      Navigator.pop(context, _content.text);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.retract ? '撤回这条消息？' : '编辑消息'),
    content: SizedBox(
      width: 450,
      child: SingleChildScrollView(
        child: !_valid
            ? const Text('工作身份已变更，旧消息内容已清空。请关闭后重新打开。')
            : _retracted
            ? const Text('这条消息已撤回')
            : !_ownsMessage
            ? const Text('只能编辑或撤回自己发送的消息。')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.retract)
                    Text(
                      _content.text.trim().isEmpty ? '附件消息' : _content.text,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    TextField(
                      controller: _content,
                      minLines: 3,
                      maxLines: 10,
                      autofocus: true,
                      decoration: const InputDecoration(hintText: '消息内容'),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, widget.retract ? false : null),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _canSubmit ? _submit : null,
        child: Text(widget.retract ? '确认撤回' : '保存'),
      ),
    ],
  );
}
