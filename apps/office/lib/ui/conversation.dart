import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import '../office_state.dart' hide Json;
import 'attachments.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'work_collections.dart';

class OfficeConversation extends StatefulWidget {
  const OfficeConversation({
    super.key,
    required this.state,
    this.onBack,
    this.mobile = false,
  });
  final OfficeState state;
  final VoidCallback? onBack;
  final bool mobile;
  @override
  State<OfficeConversation> createState() => _OfficeConversationState();
}

class _OfficeConversationState extends State<OfficeConversation> {
  static final Map<String, Json> _drafts = {};
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String? _key, _hover;
  String _query = '';
  bool _searchOpen = false, _sending = false, _loadingHistory = false;
  int _tab = 0, _messageCount = 0;
  Json? _reply;
  List<String> _mentions = [];
  List<PendingOfficeAttachment> _attachments = [];
  String? _error;
  OfficeState get s => widget.state;
  @override
  void dispose() {
    _saveDraft();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _saveDraft() {
    if (_key == null) return;
    _drafts[_key!] = {
      ...?_drafts[_key!],
      'content': _input.text,
      'reply': _reply,
      'mentions': [..._mentions],
      'attachments': [..._attachments],
    };
  }

  void _restore() {
    final next = '${s.endpoint}:${personId(s.me ?? {})}:${s.selectedRoomId}';
    if (_key == next) return;
    _saveDraft();
    _key = next;
    final draft = _drafts[next] ?? {};
    _input.text = str(draft['content']);
    _reply = draft['reply'] is Map
        ? Map<String, dynamic>.from(draft['reply'])
        : null;
    _mentions = (draft['mentions'] as List? ?? [])
        .map((e) => e.toString())
        .toList();
    _attachments = (draft['attachments'] as List? ?? [])
        .whereType<PendingOfficeAttachment>()
        .toList();
    _tab = 0;
    _error = null;
    _messageCount = 0;
    _query = '';
    _searchOpen = false;
  }

  Future<void> _send() async {
    if (_sending || (_input.text.trim().isEmpty && _attachments.isEmpty)) {
      return;
    }
    if (_attachments.any((a) => a.uploading || a.record == null)) {
      setState(() => _error = '请等待附件上传完成，或重试失败的附件。');
      return;
    }
    final text = _input.text.trim(), key = _key!;
    final mentions = [..._mentions];
    final reply = str(_reply?['id']);
    final attachmentIds = _attachments
        .map((a) => str(a.record?['id']))
        .toList();
    final signature = jsonEncode({
      'content': text,
      'mentions': mentions,
      'reply': reply,
      'attachments': attachmentIds,
    });
    final old = _drafts[key] ?? {};
    final clientId = old['signature'] == signature
        ? str(old['client_id'])
        : OfficeState.newClientId();
    _saveDraft();
    _drafts[key] = {
      ...?_drafts[key],
      'signature': signature,
      'client_id': clientId,
    };
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await s.send(
        text,
        mentions: mentions,
        replyTo: reply.isEmpty ? null : reply,
        clientId: clientId,
        attachmentIds: attachmentIds,
      );
      if (!mounted) return;
      if (_key == key &&
          jsonEncode({
                'content': _input.text.trim(),
                'mentions': _mentions,
                'reply': str(_reply?['id']),
                'attachments': _attachments
                    .map((a) => str(a.record?['id']))
                    .toList(),
              }) ==
              signature) {
        _input.clear();
        _mentions = [];
        _reply = null;
        _attachments = [];
        _drafts.remove(key);
      }
      _bottom();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _bottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  });
  Future<void> _pickAttachments() async {
    final roomId = s.selectedRoomId, draftKey = _key;
    if (roomId == null || _attachments.length >= 8) {
      notifyOffice(context, '每条消息最多添加 8 个附件。');
      return;
    }
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      for (final file in files.take(8 - _attachments.length)) {
        if (!mounted || s.selectedRoomId != roomId || _key != draftKey) return;
        final fileSize = await file.length();
        if (!mounted || s.selectedRoomId != roomId || _key != draftKey) return;
        if (fileSize > 12 * 1024 * 1024 || fileSize == 0) {
          notifyOffice(context, '附件需为 1 字节至 12 MB：${file.name}');
          continue;
        }
        final bytes = await file.readAsBytes();
        if (!mounted || s.selectedRoomId != roomId || _key != draftKey) return;
        final pending = PendingOfficeAttachment(
          filename: file.name,
          bytes: bytes,
          mimeType: imageMime(file.name),
          roomId: roomId,
        );
        setState(() => _attachments.add(pending));
        _saveDraft();
        await _upload(pending);
      }
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  Future<void> _upload(PendingOfficeAttachment item) async {
    if (item.uploading || s.selectedRoomId != item.roomId) return;
    setState(() {
      item.uploading = true;
      item.error = null;
    });
    try {
      item.record = await s.uploadAttachment(
        item.filename,
        item.bytes,
        mimeType: item.mimeType,
      );
    } catch (e) {
      item.error = friendlyError(e);
    } finally {
      item.uploading = false;
      if (mounted) {
        setState(() {});
        _saveDraft();
      }
    }
  }

  Future<void> _removeAttachment(PendingOfficeAttachment item) async {
    if (item.uploading) return;
    try {
      if (item.record != null) await s.deleteAttachment(item.record!);
      if (mounted) {
        setState(() => _attachments.remove(item));
        _saveDraft();
      }
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  Future<void> _olderMessages() async {
    if (_loadingHistory) return;
    final beforeHeight = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : 0.0;
    final beforeOffset = _scroll.hasClients ? _scroll.offset : 0.0;
    setState(() => _loadingHistory = true);
    try {
      await s.loadEarlierMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(
            (beforeOffset + _scroll.position.maxScrollExtent - beforeHeight)
                .clamp(0.0, _scroll.position.maxScrollExtent),
          );
        }
      });
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  String _name(String id) => str(
    maps(s.detail?['members'])
        .where((p) => personId(p) == id)
        .firstOrNull?['name'],
    '工作成员',
  );
  Future<void> _mention() async {
    final people = maps(s.detail?['members']);
    final id = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('提及工作成员', style: TextStyle(fontSize: 18)),
        children: people
            .map(
              (p) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, personId(p)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      PersonAvatar(
                        name: str(p['name']),
                        agent: p['kind'] == 'agent',
                        size: 30,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          str(p['name']),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IdentityBadge(agent: p['kind'] == 'agent'),
                    ],
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (id != null && mounted) {
      setState(() {
        if (!_mentions.contains(id)) _mentions.add(id);
      });
      _saveDraft();
      _focus.requestFocus();
    }
  }

  void _insert(String text) {
    final range = _input.selection;
    final start = range.isValid ? range.start : _input.text.length,
        end = range.isValid ? range.end : _input.text.length;
    _input.value = TextEditingValue(
      text: _input.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _saveDraft();
    _focus.requestFocus();
  }

  Future<void> _messageAction(Json message, String action) async {
    try {
      if (action == 'reply') {
        setState(() => _reply = message);
        _saveDraft();
        _focus.requestFocus();
      } else if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: str(message['content'])));
        if (mounted) notifyOffice(context, '消息已复制');
      } else if (action == 'edit') {
        final result = await OfficeDialogs.editText(
          context,
          str(message['content']),
        );
        if (result != null &&
            (result.trim().isNotEmpty ||
                (message['attachment_ids'] as List? ?? []).isNotEmpty)) {
          await s.editMessage(message, result);
        }
      } else if (action == 'retract') {
        await s.retractMessage(message);
      } else if (action == 'pin') {
        await s.pinMessage(message, message['pinned'] != true);
      } else if (action == 'forward') {
        final target = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('转发消息到', style: TextStyle(fontSize: 18)),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 13),
                child: Text(
                  str(message['content'], '附件消息'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              ),
              ...s.rooms.map(
                (room) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, str(room['id'])),
                  child: Row(
                    children: [
                      PersonAvatar(
                        name: str(room['name']),
                        group: room['kind'] != 'direct',
                        size: 29,
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          str(room['name']),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
        if (target != null) {
          await s.forwardMessage(message, target);
          if (mounted) notifyOffice(context, '消息已转发，附件在目标会话中独立共享。');
        }
      } else if (action.startsWith('react:')) {
        await s.react(str(message['id']), action.substring(6));
      }
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    _restore();
    final detail = s.detail;
    if (detail == null) {
      return const EmptyOffice(
        title: '消息连接彼此，文档承载共识',
        subtitle: '选择一个会话，开始共同推进工作。',
      );
    }
    final room = detail['room'] as Map? ?? {};
    final messages = maps(detail['messages']);
    if (messages.length != _messageCount) {
      final nearBottom =
          !_scroll.hasClients ||
          _scroll.position.maxScrollExtent - _scroll.offset < 120;
      if (nearBottom) _bottom();
      _messageCount = messages.length;
    }
    final filtered = messages
        .where(
          (m) => str(m['content']).toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return Column(
      children: [
        Container(
          height: 65,
          padding: EdgeInsets.symmetric(horizontal: widget.mobile ? 8 : 23),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: borderColor)),
          ),
          child: Row(
            children: [
              if (widget.onBack != null)
                IconButton(
                  onPressed: widget.onBack,
                  tooltip: '返回会话',
                  icon: const Icon(Icons.chevron_left, size: 25),
                ),
              PersonAvatar(
                name: str(room['name']),
                group: room['kind'] != 'direct',
                size: 33,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      str(room['name']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (str(room['description']).isNotEmpty)
                      Text(
                        str(room['description']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: mutedColor),
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _searchOpen = !_searchOpen),
                tooltip: '查找消息',
                icon: const Icon(Icons.search, size: 19),
              ),
              IconButton(
                onPressed: () => OfficeDialogs.members(context, s),
                tooltip: '会话成员',
                icon: const Icon(Icons.group_outlined, size: 19),
              ),
              PopupMenuButton<String>(
                tooltip: '会话设置',
                icon: const Icon(Icons.more_horiz, color: mutedColor, size: 21),
                onSelected: (v) async {
                  try {
                    if (v == 'favorite') {
                      await s.setPreferences(
                        favorite:
                            !(room['is_favorite'] == true ||
                                (room['preferences'] as Map?)?['favorite'] ==
                                    true),
                      );
                    }
                    if (v == 'mute') {
                      await s.setPreferences(muted: room['muted'] != true);
                    }
                    if (v == 'export' && context.mounted) {
                      await OfficeDialogs.export(context, s);
                    }
                  } catch (e) {
                    if (context.mounted) {
                      notifyOffice(context, friendlyError(e));
                    }
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'favorite',
                    child: Text(room['is_favorite'] == true ? '取消收藏' : '收藏会话'),
                  ),
                  PopupMenuItem(
                    value: 'mute',
                    child: Text(room['muted'] == true ? '开启消息提醒' : '消息免打扰'),
                  ),
                  const PopupMenuItem(value: 'export', child: Text('导出工作记录')),
                ],
              ),
            ],
          ),
        ),
        Container(
          height: 43,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: borderColor)),
          ),
          child: Row(
            children: List.generate(
              4,
              (i) => Padding(
                padding: const EdgeInsets.only(right: 22),
                child: InkWell(
                  onTap: () => setState(() => _tab = i),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: _tab == i ? accentColor : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Text(
                      ['消息', '云文档', '任务', '工作记录'][i],
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: _tab == i
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: _tab == i
                            ? accentColor
                            : const Color(0xff646a73),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_tab == 1)
          Expanded(child: WorkDocuments(state: s, heading: false))
        else if (_tab == 2)
          Expanded(child: WorkTasks(state: s))
        else if (_tab == 3)
          Expanded(
            child: Workbench(
              state: s,
              onDocuments: () => setState(() => _tab = 1),
              onTasks: () => setState(() => _tab = 2),
            ),
          )
        else ...[
          if (maps(s.detail?['pins']).isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(18, 10, 18, 0),
              padding: const EdgeInsets.fromLTRB(10, 3, 7, 3),
              decoration: BoxDecoration(
                color: const Color(0xfff4f7fd),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.push_pin_outlined,
                    size: 15,
                    color: accentColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '置顶：${str(maps(s.detail?['pins']).first['content'], '附件消息')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff7a8caa),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text(
                          '置顶消息',
                          style: TextStyle(fontSize: 18),
                        ),
                        content: SizedBox(
                          width: 470,
                          child: ListView(
                            shrinkWrap: true,
                            children: maps(s.detail?['pins'])
                                .map(
                                  (m) => Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          str((m['author'] as Map?)?['name']),
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: mutedColor,
                                          ),
                                        ),
                                        const SizedBox(height: 7),
                                        SelectableText(
                                          str(m['content']),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            height: 1.8,
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            Navigator.pop(context);
                                            _messageAction(m, 'pin');
                                          },
                                          child: const Text('取消置顶'),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ),
                    child: Text(
                      '${maps(s.detail?['pins']).length} 条',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
              child: OfficeSearch(
                hint: '搜索已加载的消息',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          Expanded(
            child: filtered.isEmpty
                ? const EmptyOffice(
                    title: '从一句话开始协作',
                    subtitle: '分享背景、提出问题，或邀请 Agent 共同推进。',
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.fromLTRB(
                      widget.mobile ? 13 : 25,
                      18,
                      widget.mobile ? 13 : 25,
                      18,
                    ),
                    itemCount: filtered.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return s.detail?['has_more_messages'] == true
                            ? Center(
                                child: TextButton(
                                  onPressed: _loadingHistory
                                      ? null
                                      : _olderMessages,
                                  child: Text(
                                    _loadingHistory ? '正在读取…' : '加载更早消息',
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                              )
                            : const SizedBox();
                      }
                      index -= 1;
                      final m = filtered[index];
                      final author = m['author'] is Map
                          ? Map<String, dynamic>.from(m['author'])
                          : <String, dynamic>{
                              'name': _name(str(m['author_id'])),
                              'kind': 'human',
                            };
                      final own = m['author_id'] == personId(s.me ?? {});
                      final retracted = m['retracted_at'] != null;
                      if (retracted) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: Text(
                              '${str(author['name'])} 撤回了一条消息',
                              style: const TextStyle(
                                fontSize: 10,
                                color: mutedColor,
                              ),
                            ),
                          ),
                        );
                      }
                      final reactions = m['reactions'] is Map
                          ? Map<String, dynamic>.from(m['reactions'])
                          : <String, dynamic>{};
                      final parent = messages
                          .where((item) => item['id'] == m['reply_to'])
                          .firstOrNull;
                      final menu = PopupMenuButton<String>(
                        padding: EdgeInsets.zero,
                        iconSize: 17,
                        tooltip: '消息操作',
                        onSelected: (action) => _messageAction(m, action),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'reply',
                            child: Text('回复'),
                          ),
                          const PopupMenuItem(value: 'copy', child: Text('复制')),
                          const PopupMenuItem(
                            value: 'forward',
                            child: Text('转发'),
                          ),
                          PopupMenuItem(
                            value: 'pin',
                            child: Text(m['pinned'] == true ? '取消置顶' : '置顶消息'),
                          ),
                          ...['👍', '❤️', '🎉', '👀', '✅', '🙏'].map(
                            (e) => PopupMenuItem(
                              value: 'react:$e',
                              child: Text(e),
                            ),
                          ),
                          if (own) ...[
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('编辑消息'),
                            ),
                            const PopupMenuItem(
                              value: 'retract',
                              child: Text('撤回消息'),
                            ),
                          ],
                        ],
                      );
                      return Column(
                        children: [
                          if (index == 0 ||
                              clockText(
                                    filtered[index - 1]['at'],
                                    date: true,
                                  ) !=
                                  clockText(m['at'], date: true))
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 4,
                                bottom: 18,
                              ),
                              child: Text(
                                clockText(m['at'], date: true),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xffb2b6bd),
                                ),
                              ),
                            ),
                          MouseRegion(
                            onEnter: (_) =>
                                setState(() => _hover = str(m['id'])),
                            onExit: (_) => setState(() => _hover = null),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 18),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: own
                                    ? MainAxisAlignment.end
                                    : MainAxisAlignment.start,
                                children: [
                                  if (!own) ...[
                                    PersonAvatar(
                                      name: str(author['name']),
                                      agent: author['kind'] == 'agent',
                                      size: 32,
                                    ),
                                    const SizedBox(width: 10),
                                  ],
                                  Flexible(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: widget.mobile
                                            ? MediaQuery.sizeOf(context).width *
                                                  .74
                                            : 600,
                                      ),
                                      child: Column(
                                        crossAxisAlignment: own
                                            ? CrossAxisAlignment.end
                                            : CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  str(author['name']),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    color: mutedColor,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              IdentityBadge(
                                                agent:
                                                    author['kind'] == 'agent',
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 7),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 13,
                                              vertical: 10,
                                            ),
                                            decoration: BoxDecoration(
                                              color: own
                                                  ? const Color(0xffe8efff)
                                                  : const Color(0xfff4f5f7),
                                              borderRadius:
                                                  BorderRadius.circular(7),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (m['reply_to'] != null)
                                                  Container(
                                                    margin:
                                                        const EdgeInsets.only(
                                                          bottom: 8,
                                                        ),
                                                    padding:
                                                        const EdgeInsets.only(
                                                          left: 9,
                                                        ),
                                                    decoration:
                                                        const BoxDecoration(
                                                          border: Border(
                                                            left: BorderSide(
                                                              color: Color(
                                                                0xffc2cbdc,
                                                              ),
                                                              width: 2,
                                                            ),
                                                          ),
                                                        ),
                                                    child: Text(
                                                      '回复 ${str((parent?['author'] as Map?)?['name'], '更早消息')}：${str(parent?['content'])}',
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 10,
                                                        color: mutedColor,
                                                      ),
                                                    ),
                                                  ),
                                                if (str(m['content'])
                                                    .isNotEmpty)
                                                  SelectableText(
                                                    str(m['content']),
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      height: 1.7,
                                                    ),
                                                  ),
                                                ...maps(m['attachments']).map(
                                                  (a) => MessageAttachment(
                                                    key: ValueKey(a['id']),
                                                    state: s,
                                                    attachment: {
                                                      ...a,
                                                      'room_id':
                                                          a['room_id'] ??
                                                          s.selectedRoomId,
                                                    },
                                                  ),
                                                ),
                                                if ((m['mentions'] as List? ??
                                                        [])
                                                    .isNotEmpty)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 7,
                                                        ),
                                                    child: Wrap(
                                                      spacing: 5,
                                                      children: (m['mentions'] as List)
                                                          .map(
                                                            (id) => Text(
                                                              '@${_name(id.toString())}',
                                                              style: const TextStyle(
                                                                fontSize: 11,
                                                                color:
                                                                    accentColor,
                                                              ),
                                                            ),
                                                          )
                                                          .toList(),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          if (reactions.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 5,
                                              ),
                                              child: Wrap(
                                                spacing: 5,
                                                runSpacing: 4,
                                                children: reactions.entries
                                                    .where(
                                                      (e) =>
                                                          e.value is List &&
                                                          (e.value as List)
                                                              .isNotEmpty,
                                                    )
                                                    .map(
                                                      (e) => InkWell(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              12,
                                                            ),
                                                        onTap: () =>
                                                            _messageAction(
                                                              m,
                                                              'react:${e.key}',
                                                            ),
                                                        child: Container(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 8,
                                                                vertical: 3,
                                                              ),
                                                          decoration: BoxDecoration(
                                                            color:
                                                                (e.value
                                                                        as List)
                                                                    .contains(
                                                                      personId(
                                                                        s.me ??
                                                                            {},
                                                                      ),
                                                                    )
                                                                ? selectedColor
                                                                : const Color(
                                                                    0xfff5f6f8,
                                                                  ),
                                                            border: Border.all(
                                                              color:
                                                                  borderColor,
                                                            ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  12,
                                                                ),
                                                          ),
                                                          child: Text(
                                                            '${e.key} ${(e.value as List).length}',
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 10,
                                                                ),
                                                          ),
                                                        ),
                                                      ),
                                                    )
                                                    .toList(),
                                              ),
                                            ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (m['edited_at'] != null)
                                                const Padding(
                                                  padding: EdgeInsets.only(
                                                    top: 5,
                                                  ),
                                                  child: Text(
                                                    '已编辑',
                                                    style: TextStyle(
                                                      fontSize: 9,
                                                      color: mutedColor,
                                                    ),
                                                  ),
                                                ),
                                              if (own)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 5,
                                                        left: 7,
                                                      ),
                                                  child: Text(
                                                    '${maps(s.detail?['members']).where((p) => personId(p) != personId(s.me ?? {}) && ((p['read_seq'] as num?)?.toInt() ?? 0) >= ((m['seq'] as num?)?.toInt() ?? 1)).length} 人已读',
                                                    style: const TextStyle(
                                                      fontSize: 9,
                                                      color: accentColor,
                                                    ),
                                                  ),
                                                ),
                                              if (widget.mobile ||
                                                  _hover == str(m['id']))
                                                SizedBox(
                                                  width: 25,
                                                  height: 25,
                                                  child: menu,
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (own) ...[
                                    const SizedBox(width: 10),
                                    PersonAvatar(
                                      name: str(author['name']),
                                      agent: author['kind'] == 'agent',
                                      size: 32,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          _composer(),
        ],
      ],
    );
  }

  Widget _composer() => Container(
    margin: EdgeInsets.fromLTRB(
      widget.mobile ? 11 : 22,
      0,
      widget.mobile ? 11 : 22,
      widget.mobile ? 10 : 20,
    ),
    padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xffdce0e6)),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_attachments.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 105),
            child: SingleChildScrollView(
              child: Column(
                children: _attachments
                    .map(
                      (item) => Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
                        decoration: BoxDecoration(
                          color: const Color(0xfff2f5fb),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.insert_drive_file_outlined,
                              size: 18,
                              color: Color(0xff7a95bf),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.filename,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  Text(
                                    item.uploading
                                        ? '正在上传…'
                                        : item.error != null
                                        ? item.error!
                                        : '已准备 · ${fileSizeText(item.bytes.length)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: item.error != null
                                          ? Colors.redAccent
                                          : mutedColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (item.uploading)
                              const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            if (item.error != null)
                              TextButton(
                                onPressed: () => _upload(item),
                                child: const Text(
                                  '重试',
                                  style: TextStyle(fontSize: 10),
                                ),
                              ),
                            IconButton(
                              onPressed: item.uploading
                                  ? null
                                  : () => _removeAttachment(item),
                              tooltip: '移除附件',
                              icon: const Icon(Icons.close, size: 14),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        if (_reply != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(9, 3, 3, 3),
            decoration: BoxDecoration(
              color: const Color(0xfff4f6fa),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '回复 ${str((_reply!['author'] as Map?)?['name'])}：${str(_reply!['content'])}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: mutedColor),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() => _reply = null);
                    _saveDraft();
                  },
                  icon: const Icon(Icons.close, size: 14),
                  constraints: const BoxConstraints.tightFor(
                    width: 23,
                    height: 23,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        if (_mentions.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 5,
              children: _mentions
                  .map(
                    (id) => InputChip(
                      label: Text(
                        '@${_name(id)}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: accentColor,
                        ),
                      ),
                      onDeleted: () {
                        setState(() => _mentions.remove(id));
                        _saveDraft();
                      },
                      deleteIcon: const Icon(Icons.close, size: 13),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: selectedColor,
                      side: BorderSide.none,
                    ),
                  )
                  .toList(),
            ),
          ),
        Focus(
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.enter &&
                !HardwareKeyboard.instance.isShiftPressed &&
                !(_input.value.composing.isValid &&
                    !_input.value.composing.isCollapsed)) {
              _send();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: _input,
            focusNode: _focus,
            minLines: widget.mobile ? 2 : 3,
            maxLines: 7,
            maxLength: 12000,
            style: const TextStyle(fontSize: 13, height: 1.7),
            decoration: const InputDecoration(
              hintText: '发送消息，或 @ 工作伙伴共同推进',
              filled: false,
              counterText: '',
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 3),
            ),
            onChanged: (_) => _saveDraft(),
          ),
        ),
        if (_error != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 10, color: Colors.redAccent),
            ),
          ),
        Row(
          children: [
            IconButton(
              onPressed: _attachments.length >= 8 ? null : _pickAttachments,
              tooltip: '选择图片或文件',
              icon: const Icon(Icons.attach_file, size: 19),
            ),
            PopupMenuButton<String>(
              tooltip: '插入表情',
              icon: const Icon(
                Icons.sentiment_satisfied_alt_outlined,
                size: 19,
                color: mutedColor,
              ),
              padding: const EdgeInsets.all(5),
              onSelected: _insert,
              itemBuilder: (_) => [
                '😀',
                '👍',
                '🎉',
                '❤️',
                '✅',
                '🙏',
              ].map((e) => PopupMenuItem(value: e, child: Text(e))).toList(),
            ),
            IconButton(
              onPressed: _mention,
              tooltip: '提及成员',
              icon: const Icon(Icons.alternate_email, size: 19),
            ),
            IconButton(
              onPressed: () => OfficeDialogs.document(context, s),
              tooltip: '新建共同文档',
              icon: const Icon(Icons.description_outlined, size: 18),
            ),
            IconButton(
              onPressed: () => OfficeDialogs.task(context, s),
              tooltip: '创建任务',
              icon: const Icon(Icons.add_task_outlined, size: 18),
            ),
            const Spacer(),
            if (!widget.mobile && MediaQuery.sizeOf(context).width >= 1100)
              const Padding(
                padding: EdgeInsets.only(right: 13),
                child: Text(
                  'Enter 发送 · Shift + Enter 换行',
                  style: TextStyle(fontSize: 9, color: Color(0xffb4b9c2)),
                ),
              ),
            FilledButton(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 10,
                ),
                minimumSize: const Size(0, 33),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _sending ? '发送中' : '发送',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(width: 9),
                  const Icon(Icons.send_rounded, size: 13),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
