import 'dart:async';

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'attachments.dart';
import 'business_widgets.dart';
import 'message_forward_bundle.dart';
import 'office_rich_text.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

Future<void> showOfficeMessageOriginal(
  BuildContext context,
  OfficeState state,
  String roomId,
  String messageId,
) => showDialog<void>(
  context: context,
  builder: (_) =>
      OfficeMessageOriginal(state: state, roomId: roomId, messageId: messageId),
);

class OfficeMessageOriginal extends StatefulWidget {
  const OfficeMessageOriginal({
    super.key,
    required this.state,
    required this.roomId,
    required this.messageId,
  });
  final OfficeState state;
  final String roomId, messageId;
  @override
  State<OfficeMessageOriginal> createState() => _OfficeMessageOriginalState();
}

class _OfficeMessageOriginalState extends State<OfficeMessageOriginal> {
  late final String _identity;
  Json? _message, _parent;
  String? _error;
  bool _busy = true;
  int _intent = 0;
  Timer? _refresh;
  String get _currentIdentity =>
      '${widget.state.identityGeneration}:${widget.state.endpoint}:${personId(widget.state.me ?? {})}';
  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    widget.state.addListener(_changed);
    _load();
  }

  void _changed() {
    if (!mounted) return;
    if (_identity != _currentIdentity) {
      _refresh?.cancel();
      _intent++;
      setState(() {
        _message = _parent = null;
        _busy = false;
        _error = '工作身份已切换，请重新打开原文';
      });
      return;
    }
    if (widget.state.selectedRoomId == widget.roomId) {
      final current = maps(widget.state.detail?['messages'])
          .where((m) => m['id'] == widget.messageId)
          .firstOrNull;
      if (current?['retracted_at'] != null) {
        setState(() {
          _message = current;
          _parent = null;
        });
      }
    }
    // Revalidate the source membership and the original after synchronized events.
    _refresh?.cancel();
    _refresh = Timer(
      const Duration(milliseconds: 180),
      () => _load(background: true),
    );
  }

  @override
  void dispose() {
    _intent++;
    _refresh?.cancel();
    widget.state.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load({bool background = false}) async {
    if (_identity != _currentIdentity) return;
    final intent = ++_intent;
    setState(() {
      if (!background) _busy = true;
      _error = null;
    });
    try {
      final result = await widget.state.officeRequest(
        '/rooms/${Uri.encodeComponent(widget.roomId)}/messages/${Uri.encodeComponent(widget.messageId)}',
      );
      if (!mounted || intent != _intent || _identity != _currentIdentity) {
        return;
      }
      setState(() {
        _message = Json.from(result['message']);
        _parent = result['reply_parent'] is Map
            ? Json.from(result['reply_parent'])
            : null;
      });
    } catch (e) {
      if (mounted && intent == _intent) {
        setState(() {
          _message = _parent = null;
          _error = friendlyError(e);
        });
      }
    } finally {
      if (mounted && intent == _intent) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    final author = Json.from(message?['author'] as Map? ?? {});
    return AlertDialog(
      title: const Text('消息原文'),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height * .55,
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    BusinessError(_error),
                    if (message != null) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: PersonAvatar(
                          name: officeDisplayName(author),
                          agent: author['kind'] == 'agent',
                          size: 36,
                        ),
                        title: Text(officeDisplayName(author)),
                        subtitle: Text(
                          '${author['kind'] == 'agent' ? 'Agent 同事 · ' : ''}${fullOfficeTime(message['at'], context: context)}',
                        ),
                      ),
                      if (str(author['name']).isNotEmpty &&
                          officeDisplayName(author) != str(author['name']))
                        Text(
                          '本名：${author['name']}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: mutedColor,
                          ),
                        ),
                      const Divider(height: 24),
                      if (message['hidden'] == true)
                        const Text('这条消息已从你的聊天中删除')
                      else if (message['retracted_at'] != null)
                        const Text('这条消息已撤回')
                      else ...[
                        if (_parent != null)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.reply),
                            title: Text(
                              _parent!['retracted_at'] != null
                                  ? '引用的消息已撤回'
                                  : str(_parent!['content'], '附件消息'),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => showOfficeMessageOriginal(
                              context,
                              widget.state,
                              widget.roomId,
                              str(_parent!['id']),
                            ),
                          ),
                        if (message['kind'] == 'forward_bundle' &&
                            message['forward_bundle'] is Map)
                          OfficeForwardBundleCard(
                            state: widget.state,
                            roomId: widget.roomId,
                            message: message,
                          ),
                        if (message['kind'] != 'forward_bundle' ||
                            str(message['content']).isNotEmpty)
                          OfficeRichText(
                            content: str(message['content']),
                            richText: message['rich_text'],
                            style: const TextStyle(fontSize: 14, height: 1.7),
                          ),
                        for (final attachment in maps(message['attachments']))
                          MessageAttachment(
                            state: widget.state,
                            attachment: attachment,
                          ),
                        if (message['edited_at'] != null)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              '已编辑',
                              style: TextStyle(fontSize: 11, color: mutedColor),
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (_error != null && _identity == _currentIdentity)
          TextButton(onPressed: _load, child: const Text('重试')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
