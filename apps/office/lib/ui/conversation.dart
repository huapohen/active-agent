import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import '../office_state.dart' hide Json;
import '../office_screenshot.dart';
import 'office_rich_text.dart';
import 'composer_expanded_editor.dart';
import 'attachments.dart';
import 'conversation_details.dart';
import 'room_details.dart';
import 'message_actions.dart';
import 'message_work_actions.dart';
import 'message_personal.dart';
import 'message_links.dart';
import 'message_highlights.dart';
import 'message_urgency.dart';
import 'message_forward_bundle.dart';
import 'message_hover_tools.dart';
import 'message_thread.dart';
import 'message_receipts.dart';
import 'office_emoji.dart';
import 'message_original.dart';
import 'message_edit_dialog.dart';
import 'agent_collaboration.dart';
import 'agent_message_content.dart';
import 'mentions.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'work_collections.dart';

class OfficeConversation extends StatefulWidget {
  const OfficeConversation({
    super.key,
    required this.state,
    this.onBack,
    this.mobile = false,
    this.onAgentStore,
    this.onCreateCalendar,
    this.onCreateMeeting,
  });
  final OfficeState state;
  final VoidCallback? onBack;
  final bool mobile;
  final VoidCallback? onAgentStore;
  final VoidCallback? onCreateCalendar, onCreateMeeting;
  @override
  State<OfficeConversation> createState() => _OfficeConversationState();
}

class _OfficeConversationState extends State<OfficeConversation>
    with WidgetsBindingObserver {
  String? _visibleRoom;
  int _visibleSelection = -1, _positionVersion = -1;
  final _viewportKey = GlobalKey();
  final _messageKeys = <String, GlobalKey>{};
  Timer? _viewportTimer;
  bool _positioning = false, _awayFromBottom = false;
  bool _resumed = true, _pageActive = true;
  int _panels = 0;
  Future<T?> _showPanel<T>(Future<T?> Function() open) async {
    _panels++;
    _syncVisibility();
    try {
      return await open();
    } finally {
      _panels--;
      if (mounted) _syncVisibility();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    s.addListener(_draftScopeChanged);
    _input.addListener(_rebaseComposerRichText);
    _scroll.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(covariant OfficeConversation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_draftScopeChanged);
      s.addListener(_draftScopeChanged);
      _restore();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageActive =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncVisibility();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _syncVisibility();
  }

  Future<void> _setVisible(String roomId, bool visible) async {
    try {
      await s.setConversationVisible(roomId, visible);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  void _syncVisibility() {
    final roomId = s.selectedRoomId;
    final next = _resumed && _pageActive && _tab == 0 && _panels == 0
        ? roomId
        : null;
    if (_visibleRoom == next && _visibleSelection == s.conversationSelection) {
      if (next != null) _queueVisibleReport();
      return;
    }
    if (_visibleRoom != null) unawaited(_setVisible(_visibleRoom!, false));
    _visibleRoom = next;
    _visibleSelection = s.conversationSelection;
    if (next != null) unawaited(_setVisible(next, true));
    if (next != null) _queueVisibleReport();
  }

  void _scrolled() {
    final away =
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent - _scroll.offset > 120;
    if (mounted && away != _awayFromBottom) {
      setState(() => _awayFromBottom = away);
    }
    _queueVisibleReport();
  }

  void _queueVisibleReport() {
    if (_viewportTimer?.isActive == true || _positioning) return;
    final roomId = s.selectedRoomId, identity = _identity;
    final selection = s.conversationSelection,
        generation = s.identityGeneration;
    _viewportTimer = Timer(const Duration(milliseconds: 120), () async {
      if (!mounted ||
          _positioning ||
          _visibleRoom != roomId ||
          roomId == null ||
          _identity != identity ||
          s.conversationSelection != selection ||
          !_resumed ||
          !_pageActive ||
          _panels != 0 ||
          _tab != 0) {
        return;
      }
      final viewport = _viewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
        return;
      }
      final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
      final visible = <int>[];
      for (final message in maps(s.detail?['messages'])) {
        final box = _messageKeys[str(message['id'])]?.currentContext
            ?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        final overlap = bounds.intersect(rect);
        final sequence = (message['seq'] as num?)?.toInt();
        if (sequence != null &&
            overlap.width > 0 &&
            overlap.height >= (rect.height < 48 ? rect.height / 2 : 24)) {
          visible.add(sequence);
        }
      }
      try {
        await s.reportVisibleMessageSequences(
          roomId,
          visible,
          selection: selection,
          identityGeneration: generation,
        );
      } catch (e) {
        if (mounted && _identity == identity) {
          setState(() => _error = friendlyError(e));
        }
      }
    });
  }

  void _positionWindow(OfficeConversationWindow window) {
    _positionVersion = window.positionVersion;
    _positioning = true;
    final identity = _identity, selection = s.conversationSelection;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          identity != _identity ||
          selection != s.conversationSelection) {
        return;
      }
      if (_scroll.hasClients) {
        _scroll.jumpTo(
          (window.startAtUnread || window.anchorSeq != null)
              ? 0
              : _scroll.position.maxScrollExtent,
        );
      }
      _positioning = false;
      _syncVisibility();
      _scrolled();
    });
  }

  Future<void> _latestMessages() async {
    try {
      await s.jumpToLatestMessages();
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  Future<void> _laterMessages() async {
    try {
      await s.loadLaterMessages();
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  static final Map<String, Json> _drafts = {};
  final _input = OfficeRichTextEditingController();
  Json? _richText;
  String _expandedTitle = "";
  void _rebaseComposerRichText() => _richText = _input.richText;
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String? _key, _draftIdentity, _draftRoomId;
  bool _sending = false, _loadingHistory = false, _mentionOpen = false;
  int _tab = 0, _messageCount = 0;
  bool _mobileFormatting = false;
  bool _moreTools = false, _savingSendMode = false, _screenshotBusy = false;
  final _screenshot = OfficeScreenshotService();
  Json? _reply;
  List<String> _mentions = [];
  bool _mentionAll = false;
  int _sendOperation = 0;
  String get _identity =>
      '${identityHashCode(s)}:${s.identityGeneration}:${s.endpoint}:${personId(s.me ?? {})}';
  String get _currentDraftKey =>
      '${s.endpoint}:${personId(s.me ?? {})}:${s.selectedRoomId}';
  Json? get _selectedRoom =>
      s.selectedRoomId != null &&
          (s.detail?['room'] as Map?)?['id'] == s.selectedRoomId
      ? Json.from(s.detail!['room'] as Map)
      : s.rooms.where((room) => room['id'] == s.selectedRoomId).firstOrNull;
  bool get _direct => _selectedRoom?['kind'] == 'direct';
  void _draftScopeChanged() {
    if (!mounted) return;
    if (_draftIdentity != _identity ||
        _draftRoomId != s.selectedRoomId ||
        (_direct && _mentionAll)) {
      setState(_restore);
    }
  }

  List<PendingOfficeAttachment> _attachments = [];
  String? _error;
  OfficeState get s => widget.state;
  @override
  void dispose() {
    s.removeListener(_draftScopeChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (_visibleRoom != null) unawaited(_setVisible(_visibleRoom!, false));
    _saveDraft();
    _input.removeListener(_rebaseComposerRichText);
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    _viewportTimer?.cancel();
    super.dispose();
  }

  void _saveDraft() {
    if (_key == null) return;
    _drafts[_key!] = {
      ...?_drafts[_key!],
      'content': _input.text,
      'rich_text': _richText,
      'expanded_title': _expandedTitle,
      'reply': _reply,
      'mentions': [..._mentions],
      'mention_all': _mentionAll,
      'attachments': [..._attachments],
    };
  }

  void _restore() {
    final next = _currentDraftKey;
    if (_key == next && _draftIdentity == _identity) {
      if (_direct && _mentionAll) {
        _mentionAll = false;
        _saveDraft();
      }
      return;
    }
    _saveDraft();
    _key = next;
    _draftIdentity = _identity;
    _draftRoomId = s.selectedRoomId;
    _sendOperation++;
    _sending = false;
    final draft = _drafts[next] ?? {};
    _expandedTitle = str(draft['expanded_title']);
    _input.setRichValue(
      OfficeRichTextValue(
        content: str(draft['content']),
        richText: draft['rich_text'] is Map
            ? Json.from(draft['rich_text'] as Map)
            : null,
      ),
    );
    _reply = draft['reply'] is Map
        ? Map<String, dynamic>.from(draft['reply'])
        : null;
    final selection = OfficeMentionSelection.fromDraft(draft, group: !_direct);
    _mentions = selection.selectedIds.toList();
    _mentionAll = selection.mentionAll;
    _attachments = (draft['attachments'] as List? ?? [])
        .whereType<PendingOfficeAttachment>()
        .toList();
    _tab = 0;
    _error = null;
    _messageCount = 0;
    _moreTools = false;
    _mobileFormatting = false;
    _selectedMessages.clear();
    _selectingMessages = false;
    _selectionBusy = false;
    _positionVersion = -1;
    _messageKeys.clear();
    _positioning = false;
    _awayFromBottom = false;
  }

  Future<void> _send() async {
    if (_key != _currentDraftKey ||
        _draftIdentity != _identity ||
        _draftRoomId != s.selectedRoomId ||
        s.me == null ||
        !s.connected) {
      return;
    }
    if (_sending || (_input.text.trim().isEmpty && _attachments.isEmpty)) {
      return;
    }
    if (_attachments.any((a) => a.uploading || a.record == null)) {
      setState(() => _error = '请等待附件上传完成，或重试失败的附件。');
      return;
    }
    final preparedText = officeTrimRichText(_input.text, _richText);
    final text = preparedText.content, key = _key!;
    final richText = preparedText.richText;
    final mentions = [..._mentions];
    final mentionAll = !_direct && _mentionAll;
    final identity = _identity, sourceRoomId = _draftRoomId;
    final operation = ++_sendOperation;
    final reply = str(_reply?['id']);
    final attachmentIds = _attachments
        .map((a) => str(a.record?['id']))
        .toList();
    final signature = jsonEncode({
      'content': text,
      'rich_text': ?richText,
      'mentions': mentions,
      'mention_all': mentionAll,
      'reply': reply,
      'attachments': attachmentIds,
    });
    final old = _drafts[key] ?? {};
    final legacySignature = jsonEncode({
      'content': text,
      'mentions': mentions,
      'reply': reply,
      'attachments': attachmentIds,
    });
    final clientId =
        (old['signature'] == signature ||
                (!mentionAll &&
                    richText == null &&
                    old['signature'] == legacySignature)) &&
            str(old['client_id']).isNotEmpty
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
        richText: richText,
        mentions: mentions,
        mentionAll: mentionAll,
        sourceRoomId: sourceRoomId,
        replyTo: reply.isEmpty ? null : reply,
        clientId: clientId,
        attachmentIds: attachmentIds,
      );
      if (!mounted || _identity != identity) return;
      // Acknowledging the source room must not clear a newer draft elsewhere.
      final stored = _drafts[key];
      if (stored != null &&
          jsonEncode({
                'content': str(stored['content']).trim(),
                if (officeTrimRichText(
                      str(stored['content']),
                      stored['rich_text'] is Map
                          ? Json.from(stored['rich_text'] as Map)
                          : null,
                    ).richText
                    case final Json storedRich)
                  'rich_text': storedRich,
                'mentions': (stored['mentions'] as List? ?? []),
                'mention_all': stored['mention_all'] == true,
                'reply': str((stored['reply'] as Map?)?['id']),
                'attachments': (stored['attachments'] as List? ?? [])
                    .whereType<PendingOfficeAttachment>()
                    .map((item) => str(item.record?['id']))
                    .toList(),
              }) ==
              signature) {
        _drafts.remove(key);
      }
      if (_key == key &&
          jsonEncode({
                'content': _input.text.trim(),
                if (officeTrimRichText(_input.text, _richText).richText
                    case final Json currentRich)
                  'rich_text': currentRich,
                'mentions': _mentions,
                'mention_all': _mentionAll,
                'reply': str(_reply?['id']),
                'attachments': _attachments
                    .map((a) => str(a.record?['id']))
                    .toList(),
              }) ==
              signature) {
        _input.clear();
        _expandedTitle = '';
        _mentions = [];
        _mentionAll = false;
        _reply = null;
        _attachments = [];
        _drafts.remove(key);
      }
      if (_key == key) await _latestMessages();
    } catch (e) {
      if (mounted &&
          _identity == identity &&
          _key == key &&
          operation == _sendOperation) {
        setState(() => _error = friendlyError(e));
      }
    } finally {
      if (mounted && operation == _sendOperation) {
        setState(() => _sending = false);
      }
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
    final roomId = s.selectedRoomId, draftKey = _key, identity = _identity;
    if (roomId == null || _attachments.length >= 8) {
      notifyOffice(context, '每条消息最多添加 8 个附件。');
      return;
    }
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      for (final file in files.take(8 - _attachments.length)) {
        if (!mounted ||
            _identity != identity ||
            s.selectedRoomId != roomId ||
            _key != draftKey) {
          return;
        }
        final fileSize = await file.length();
        if (!mounted ||
            _identity != identity ||
            s.selectedRoomId != roomId ||
            _key != draftKey) {
          return;
        }
        if (fileSize > 12 * 1024 * 1024 || fileSize == 0) {
          notifyOffice(context, '附件需为 1 字节至 12 MB：${file.name}');
          continue;
        }
        final bytes = await file.readAsBytes();
        if (!mounted ||
            _identity != identity ||
            s.selectedRoomId != roomId ||
            _key != draftKey) {
          return;
        }
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
    final identity = _identity, roomId = s.selectedRoomId;
    final selection = s.conversationSelection;
    String? anchorId;
    double? anchorTop;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is RenderBox && viewport.hasSize) {
      final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
      for (final message in maps(s.detail?['messages'])) {
        final id = str(message['id']);
        final box = _messageKeys[id]?.currentContext?.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final rect = box.localToGlobal(Offset.zero) & box.size;
          if (rect.overlaps(bounds)) {
            anchorId = id;
            anchorTop = rect.top;
            break;
          }
        }
      }
    }
    final beforeHeight = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : 0.0;
    final beforeOffset = _scroll.hasClients ? _scroll.offset : 0.0;
    setState(() => _loadingHistory = true);
    try {
      await s.loadEarlierMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _identity == identity &&
            s.selectedRoomId == roomId &&
            s.conversationSelection == selection &&
            _scroll.hasClients) {
          final anchor = _messageKeys[anchorId]?.currentContext
              ?.findRenderObject();
          final offset =
              anchor is RenderBox && anchor.hasSize && anchorTop != null
              ? _scroll.offset +
                    anchor.localToGlobal(Offset.zero).dy -
                    anchorTop
              : beforeOffset + _scroll.position.maxScrollExtent - beforeHeight;
          _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
        }
      });
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  String _name(String id) => officeDisplayName(
    maps(s.detail?['members']).where((p) => personId(p) == id).firstOrNull ??
        {},
  );
  final _actingMessages = <String>{};
  Future<void> _openMessageActions(Json message, [Offset? position]) async {
    final roomId = s.selectedRoomId;
    final identity = _identity;
    final action = await _showPanel(
      () => showOfficeMessageActions(
        context,
        message,
        own: message['author_id'] == personId(s.me ?? {}),
        position: position,
        state: s,
      ),
    );
    if (action != null &&
        mounted &&
        s.selectedRoomId == roomId &&
        identity == _identity) {
      await _messageAction(message, action);
    }
  }

  Future<void> _mention({int? atPosition}) async {
    if (_mentionOpen) return;
    _mentionOpen = true;
    final roomId = s.selectedRoomId;
    final identity = _identity;
    final draftKey = _key;
    var expired = false;
    bool currentScope() =>
        mounted &&
        _identity == identity &&
        s.selectedRoomId == roomId &&
        _key == draftKey;
    final people = maps(s.detail?['members']);
    final selection = await _showPanel(
      () => showDialog<OfficeMentionSelection>(
        context: context,
        builder: (context) => AnimatedBuilder(
          animation: s,
          builder: (context, _) {
            expired = expired || !currentScope();
            if (expired) {
              return AlertDialog(
                title: const Text('会话已变化'),
                content: const Text('当前工作身份或会话已变化，请关闭后重新选择提及对象。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              );
            }
            return OfficeMentionPicker(
              people: people,
              selected: _mentions,
              mentionAll: _mentionAll,
              mobile: widget.mobile,
              group: !_direct,
            );
          },
        ),
      ),
    );
    _mentionOpen = false;
    if (selection != null && !expired && currentScope()) {
      setState(() {
        _mentions = selection.selectedIds.toList();
        _mentionAll = !_direct && selection.mentionAll;
        if (atPosition != null &&
            atPosition < _input.text.length &&
            _input.text[atPosition] == '@') {
          _input.value = TextEditingValue(
            text: _input.text.replaceRange(atPosition, atPosition + 1, ''),
            selection: TextSelection.collapsed(offset: atPosition),
          );
        }
      });
      _saveDraft();
      _focus.requestFocus();
    }
  }

  void _inputChanged(String value) {
    _saveDraft();
    final end = _input.selection.baseOffset;
    if (!_mentionOpen &&
        end > 0 &&
        end <= value.length &&
        value[end - 1] == '@' &&
        (end == 1 || RegExp(r'\s').hasMatch(value[end - 2])) &&
        !(_input.value.composing.isValid &&
            !_input.value.composing.isCollapsed)) {
      _mention(atPosition: end - 1);
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
    final sourceRoomId = s.selectedRoomId;
    final identity = _identity;
    bool sameIdentity() => mounted && identity == _identity;
    final operationKey = '$identity:$sourceRoomId:${message['id']}';
    if (!_actingMessages.add(operationKey)) return;
    try {
      if (action == 'multi_select') {
        setState(() {
          _selectingMessages = true;
          _selectedMessages[str(message['id'])] = Json.from(message);
        });
        _focus.unfocus();
      } else if (action == 'mark' && sourceRoomId != null) {
        await s.setMessagePersonal(
          sourceRoomId,
          str(message['id']),
          marked: (message['personal_preferences'] as Map?)?['marked'] != true,
        );
      } else if (action == 'hide' && sourceRoomId != null) {
        await s.setMessagePersonal(
          sourceRoomId,
          str(message['id']),
          hidden: true,
        );
        if (mounted && sameIdentity()) {
          notifyOffice(context, '已从你的聊天中删除，可在会话详情的已删除消息中恢复。');
        }
      } else if (action == 'forwarding' && sourceRoomId != null) {
        await s.setMessageForwarding(
          sourceRoomId,
          message,
          message['forwarding_own_no_forward'] != true,
        );
      } else if (action == 'copy_link' && sourceRoomId != null) {
        await Clipboard.setData(
          ClipboardData(
            text: officeMessageLink(
              s.endpoint,
              sourceRoomId,
              str(message['id']),
            ),
          ),
        );
        if (mounted && sameIdentity()) {
          notifyOffice(context, '消息链接已复制，仅有会话权限的成员可打开。');
        }
      } else if ((action == 'task' || action == 'export') &&
          sourceRoomId != null) {
        final result = await _showPanel(
          () => action == 'task'
              ? showOfficeMessageTask(context, s, sourceRoomId, [message])
              : showOfficeMessageExport(context, s, sourceRoomId, [message]),
        );
        if (result != null &&
            sameIdentity() &&
            s.selectedRoomId == sourceRoomId) {
          setState(() => _tab = action == 'task' ? 2 : 1);
        }
      } else if (action == 'original') {
        if (sourceRoomId != null) {
          await _showPanel(
            () => showOfficeMessageOriginal(
              context,
              s,
              sourceRoomId,
              str(message['id']),
            ),
          );
        }
      } else if (action == 'topic') {
        if (sourceRoomId != null) {
          await _showPanel(
            () => showOfficeMessageThread(
              context,
              s,
              sourceRoomId,
              message,
              createTopic: true,
            ),
          );
        }
      } else if (action == 'agent') {
        final sourceIdentity = _identity;
        bool current() =>
            mounted &&
            _identity == sourceIdentity &&
            s.selectedRoomId == sourceRoomId;
        await _showPanel(
          () => showAgentCollaboration(
            context,
            s,
            onMention: (ids) {
              if (!current()) return;
              setState(() {
                _reply = message;
                _mentions = {..._mentions, ...ids}.toList();
              });
              _saveDraft();
              _focus.requestFocus();
            },
            onRecords: () {
              if (mounted && current()) setState(() => _tab = 3);
            },
            onStore: () {
              if (mounted && current()) widget.onAgentStore?.call();
            },
          ),
        );
      } else if (action == 'read') {
        if (sourceRoomId != null) {
          await _showPanel(
            () => showOfficeMessageReceipts(context, s, sourceRoomId, message),
          );
        }
      } else if (action == 'emoji') {
        final emoji = await _showPanel(() => showOfficeEmojiPicker(context, s));
        if (emoji != null &&
            sameIdentity() &&
            s.selectedRoomId == sourceRoomId) {
          await s.react(str(message['id']), emoji);
        }
      } else if (action == 'reply') {
        setState(() => _reply = message);
        _saveDraft();
        _focus.requestFocus();
      } else if (action == 'copy') {
        final text = message['kind'] == 'forward_bundle' && sourceRoomId != null
            ? await officeForwardBundleCopyText(s, sourceRoomId, message)
            : str(message['content']);
        if (!mounted || !sameIdentity() || s.selectedRoomId != sourceRoomId) {
          return;
        }
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted && sameIdentity()) notifyOffice(context, '消息已复制');
      } else if (action == 'select') {
        final text = message['kind'] == 'forward_bundle' && sourceRoomId != null
            ? await officeForwardBundleCopyText(s, sourceRoomId, message)
            : str(message['content']);
        if (!mounted || !sameIdentity() || s.selectedRoomId != sourceRoomId) {
          return;
        }
        await _showPanel(
          () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('选择文本'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: OfficeEmojiText(content: text),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    try {
                      if (!sameIdentity() || s.selectedRoomId != sourceRoomId) {
                        return;
                      }
                      final currentText =
                          message['kind'] == 'forward_bundle' &&
                              sourceRoomId != null
                          ? await officeForwardBundleCopyText(
                              s,
                              sourceRoomId,
                              message,
                            )
                          : text;
                      if (!sameIdentity() || s.selectedRoomId != sourceRoomId) {
                        return;
                      }
                      await Clipboard.setData(ClipboardData(text: currentText));
                    } catch (error) {
                      if (context.mounted && sameIdentity()) {
                        notifyOffice(context, friendlyError(error));
                      }
                    }
                  },
                  child: const Text('复制全文'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
        );
      } else if (action == 'edit') {
        final result = await _showPanel(
          () => showOfficeMessageEdit(context, s, message),
        );
        if (result != null &&
            sameIdentity() &&
            (result.content.trim().isNotEmpty ||
                (message['attachment_ids'] as List? ?? []).isNotEmpty ||
                (message['kind'] == 'forward_bundle' &&
                    message['forward_bundle'] is Map))) {
          await s.editMessage(
            message,
            result.content,
            sourceRoomId: sourceRoomId,
            richText: result.richText,
          );
        }
      } else if (action == 'retract') {
        final confirmed = await _showPanel(
          () => confirmOfficeMessageRetraction(context, s, message),
        );
        if (confirmed == true && sameIdentity()) {
          await s.retractMessage(message, sourceRoomId: sourceRoomId);
        }
      } else if (action == 'highlight' && sourceRoomId != null) {
        await _showPanel(
          () => showOfficeMessageHighlight(
            context,
            s,
            sourceRoomId,
            message: message,
            onOpenMessage: (id) =>
                _focusMessageFromPanel(sourceRoomId, id, identity),
          ),
        );
      } else if (action == 'urgency' && sourceRoomId != null) {
        await _showPanel(
          () => showOfficeMessageUrgency(context, s, sourceRoomId, message),
        );
      } else if (action == 'pin') {
        await s.pinMessage(message, message['pinned'] != true);
      } else if (action == 'forward') {
        final roomId = s.selectedRoomId;
        final target = await _showPanel(
          () => showOfficeForwardPicker(context, s.rooms, message),
        );
        if (target != null && roomId != null && sameIdentity()) {
          await s.forwardMessage(message, target, sourceRoomId: roomId);
          if (mounted && sameIdentity()) {
            notifyOffice(context, '消息已转发，附件在目标会话中独立共享。');
          }
        }
      } else if (action.startsWith('react:')) {
        await s.react(str(message['id']), action.substring(6));
      }
    } catch (e) {
      if (mounted && sameIdentity()) notifyOffice(context, friendlyError(e));
    } finally {
      _actingMessages.remove(operationKey);
    }
  }

  Future<void> _focusMessageFromPanel(
    String roomId,
    String messageId,
    String identity,
  ) async {
    if (!mounted || _identity != identity || s.selectedRoomId != roomId) return;
    try {
      await s.focusMessage(roomId, messageId);
    } catch (error) {
      if (mounted && _identity == identity) {
        notifyOffice(context, friendlyError(error));
      }
    }
  }

  final _selectedMessages = <String, Json>{};
  bool _selectingMessages = false, _selectionBusy = false;

  Future<void> _personalMessages({bool hidden = false}) async {
    final roomId = s.selectedRoomId, identity = _identity;
    final chosen = await _showPanel(
      () => showOfficePersonalMessages(
        context,
        s,
        roomId: roomId,
        hidden: hidden,
      ),
    );
    if (chosen != null && mounted && identity == _identity) {
      try {
        await s.focusMessage(
          str(chosen['room_id']),
          str((chosen['message'] as Map?)?['id']),
        );
      } catch (error) {
        if (mounted && identity == _identity) {
          notifyOffice(context, friendlyError(error));
        }
      }
    }
  }

  void _toggleSelected(Json message) {
    if (_selectionBusy) return;
    final id = str(message['id']);
    if (!_selectedMessages.containsKey(id) && _selectedMessages.length >= 50) {
      notifyOffice(context, '一次最多选择 50 条消息');
      return;
    }
    setState(() {
      if (_selectedMessages.containsKey(id)) {
        _selectedMessages.remove(id);
      } else {
        _selectedMessages[id] = Json.from(message);
      }
    });
  }

  Widget _selectionWrapper(Json message, Widget child) {
    if (!_selectingMessages) return child;
    return InkWell(
      key: ValueKey('message-actions-${message['id']}'),
      onTap: _selectionBusy ? null : () => _toggleSelected(message),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            key: ValueKey('select-message-${message['id']}'),
            value: _selectedMessages.containsKey(str(message['id'])),
            onChanged: _selectionBusy ? null : (_) => _toggleSelected(message),
          ),
          Expanded(child: IgnorePointer(child: child)),
        ],
      ),
    );
  }

  Widget _selectionBar() => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('已选择 ${_selectedMessages.length} / 50 条'),
                const Spacer(),
                if (_selectionBusy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                TextButton(
                  onPressed: _selectionBusy
                      ? null
                      : () => setState(() {
                          _selectingMessages = false;
                          _selectedMessages.clear();
                        }),
                  child: const Text('取消多选'),
                ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final action in [
                    if ((s.detail?['native_features']
                            as Map?)?['message_forward_bundles'] ==
                        true)
                      ('merge_forward', '合并转发', Icons.forum_outlined),
                    ('forward', '逐条转发', Icons.forward_outlined),
                    ('copy_link', '复制消息链接', Icons.link),
                    ('task', '添加任务', Icons.task_alt),
                    ('export', '导出到文档', Icons.description_outlined),
                    ('copy', '复制文本', Icons.copy_outlined),
                    ('hide', '删除', Icons.delete_outline),
                  ])
                    SizedBox(
                      width: widget.mobile ? 82 : 102,
                      child: TextButton(
                        key: ValueKey('selected-messages-${action.$1}'),
                        onPressed: _selectionBusy || _selectedMessages.isEmpty
                            ? null
                            : () => _selectionAction(action.$1),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(action.$3, size: 23),
                            const SizedBox(height: 8),
                            Text(
                              action.$2,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _selectionAction(String action) async {
    if (_selectionBusy || _selectedMessages.isEmpty) return;
    final identity = _identity, roomId = s.selectedRoomId;
    if (roomId == null) return;
    final messages = _selectedMessages.values.map(Json.from).toList()
      ..sort(
        (a, b) => ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0),
      );
    bool current() =>
        mounted && identity == _identity && s.selectedRoomId == roomId;
    setState(() => _selectionBusy = true);
    try {
      if (action == 'merge_forward') {
        final result = await _showPanel(
          () => showOfficeMergedForward(context, s, roomId, messages),
        );
        if (result == null || !mounted || !current()) return;
        setState(() => _selectedMessages.clear());
        notifyOffice(context, '聊天记录已合并转发');
      } else if (action == 'task' || action == 'export') {
        final result = await _showPanel(
          () => action == 'task'
              ? showOfficeMessageTask(context, s, roomId, messages)
              : showOfficeMessageExport(context, s, roomId, messages),
        );
        if (result == null || !current()) return;
        setState(() {
          _selectedMessages.clear();
          _tab = action == 'task' ? 2 : 1;
        });
      } else if (action == 'copy' || action == 'copy_link') {
        final fresh = <Json>[];
        for (final message in messages) {
          if (!current()) return;
          final result = await s.officeRequest(
            '/rooms/${Uri.encodeComponent(roomId)}/messages/${Uri.encodeComponent(str(message['id']))}',
          );
          if (!current()) return;
          final value = Json.from(result['message'] as Map? ?? {});
          if (value['id'] != message['id'] ||
              value['hidden'] == true ||
              value['retracted_at'] != null) {
            throw OfficeException(409, '所选消息已删除或撤回，请重新选择');
          }
          fresh.add(value);
        }
        final texts = <String>[];
        for (final message in fresh) {
          if (!current()) return;
          texts.add(
            action == 'copy_link'
                ? officeMessageLink(s.endpoint, roomId, str(message['id']))
                : message['kind'] == 'forward_bundle'
                ? await officeForwardBundleCopyText(s, roomId, message)
                : str(message['content']),
          );
        }
        if (!current()) return;
        await Clipboard.setData(ClipboardData(text: texts.join('\n\n')));
        if (mounted && current()) {
          notifyOffice(
            context,
            '已复制 ${messages.length} 条消息${action == 'copy_link' ? '链接' : ''}',
          );
        }
        return;
      } else {
        String? target;
        if (action == 'forward') {
          target = await _showPanel(
            () => showOfficeForwardPicker(context, s.rooms, {
              'content': '逐条转发 ${messages.length} 条消息',
            }),
          );
          if (target == null || !current()) return;
        }
        for (final message in messages) {
          if (!current()) return;
          if (action == 'hide') {
            await s.setMessagePersonal(
              roomId,
              str(message['id']),
              hidden: true,
            );
          } else {
            await s.forwardMessage(message, target!, sourceRoomId: roomId);
          }
          if (!current()) return;
          setState(() => _selectedMessages.remove(str(message['id'])));
        }
        if (mounted && current()) {
          notifyOffice(
            context,
            action == 'hide' ? '已从你的聊天中删除，可在会话详情中恢复。' : '消息已逐条转发',
          );
        }
      }
      if (current() && _selectedMessages.isEmpty) {
        setState(() => _selectingMessages = false);
      }
    } catch (error) {
      if (mounted && current()) {
        notifyOffice(context, '${friendlyError(error)}，未完成的消息仍保留选择。');
      }
    } finally {
      if (mounted && current()) setState(() => _selectionBusy = false);
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
    final viewIdentity = _identity;
    final messages = maps(detail['messages']);
    final loadedIds = messages.map((message) => str(message['id'])).toSet();
    _messageKeys.removeWhere((id, _) => !loadedIds.contains(id));
    final window = s.conversationWindow;
    final unreadRemaining =
        (s.rooms
                    .where((r) => r['id'] == room['id'])
                    .firstOrNull?['unread_count']
                as num?)
            ?.toInt() ??
        window?.remainingUnreadAfter ??
        0;
    if (window != null && window.positionVersion != _positionVersion) {
      _positionWindow(window);
    }
    if (messages.length != _messageCount) {
      final nearBottom =
          !_scroll.hasClients ||
          _scroll.position.maxScrollExtent - _scroll.offset < 120;
      if (nearBottom &&
          !_positioning &&
          !_loadingHistory &&
          window?.hasMoreAfter != true &&
          window?.startAtUnread != true &&
          window?.anchorSeq == null) {
        _bottom();
      }
      _messageCount = messages.length;
    }
    if (_reply != null) {
      final latestReply = messages
          .where((m) => m['id'] == _reply!['id'])
          .firstOrNull;
      if (latestReply != null) _reply = latestReply;
    }
    final filtered = messages;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncVisibility();
    });
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
                onPressed: () => _showPanel(
                  () => showOfficeRoomSearch(context, s, str(room['id'])),
                ),
                tooltip: '查找消息',
                icon: const Icon(Icons.search, size: 19),
              ),
              IconButton(
                onPressed: () =>
                    _showPanel(() => OfficeDialogs.members(context, s)),
                tooltip: '会话成员',
                icon: const Icon(Icons.group_outlined, size: 19),
              ),
              IconButton(
                tooltip: '会话设置',
                icon: const Icon(Icons.more_horiz, color: mutedColor, size: 21),
                onPressed: () {
                  final roomId = str(room['id']);
                  void openTab(int tab) {
                    if (mounted && s.selectedRoomId == roomId) {
                      setState(() => _tab = tab);
                    }
                  }

                  _showPanel(
                    () => showOfficeRoomDetails(
                      context,
                      s,
                      roomId: roomId,
                      onSearch: () {
                        if (mounted && s.selectedRoomId == roomId) {
                          showOfficeRoomSearch(context, s, roomId);
                        }
                      },
                      onDocuments: () => openTab(1),
                      onTasks: () => openTab(2),
                      onRecords: () => openTab(3),
                      onMarkedMessages: () => _personalMessages(),
                      onHiddenMessages: () => _personalMessages(hidden: true),
                      onUrgencies: () => _showPanel(
                        () => showOfficeRoomUrgencies(context, s, roomId),
                      ),
                      onMembers: () {
                        if (mounted && s.selectedRoomId == roomId) {
                          _showPanel(() => OfficeDialogs.members(context, s));
                        }
                      },
                    ),
                  );
                },
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
        if ((_tab == 1 && !s.moduleAvailable('docs')) ||
            (_tab == 2 && !s.moduleAvailable('tasks')) ||
            (_tab == 3 && !s.moduleAvailable('workbench')))
          const Expanded(
            child: EmptyOffice(
              title: '企业策略限制了此应用',
              subtitle: '请联系企业管理员调整你的应用可用范围。',
              icon: Icons.lock_outline,
            ),
          )
        else if (_tab == 1)
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
          if ((detail['native_features'] as Map?)?['message_highlights'] ==
              true)
            OfficeMessageHighlightsBanner(
              key: ValueKey('highlights-$_identity-${room['id']}'),
              state: s,
              roomId: str(room['id']),
              onOpenMessage: (id) =>
                  _focusMessageFromPanel(str(room['id']), id, viewIdentity),
              onManage: () => _showPanel(
                () => showOfficeMessageHighlight(
                  context,
                  s,
                  str(room['id']),
                  onOpenMessage: (id) =>
                      _focusMessageFromPanel(str(room['id']), id, viewIdentity),
                ),
              ),
            ),
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
                      'Pin：${str(maps(s.detail?['pins']).first['content'], '附件消息')}',
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
                          'Pin 消息',
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
                                          officeDisplayName(
                                            Json.from(
                                              m['author'] as Map? ?? {},
                                            ),
                                          ),
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
                                          child: const Text('取消 Pin'),
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
          Expanded(
            child: Stack(
              key: _viewportKey,
              children: [
                Positioned.fill(
                  child: filtered.isEmpty
                      ? const EmptyOffice(
                          title: '从一句话开始协作',
                          subtitle: '分享背景、提出问题，或邀请 Agent 共同推进。',
                        )
                      : ListView.builder(
                          controller: _scroll,
                          findChildIndexCallback: (key) {
                            if (key is! ValueKey<String>) return null;
                            final index = filtered.indexWhere(
                              (m) => key.value == 'message-actions-${m['id']}',
                            );
                            return index < 0 ? null : index + 1;
                          },
                          padding: EdgeInsets.fromLTRB(
                            widget.mobile ? 13 : 25,
                            18,
                            widget.mobile ? 13 : 25,
                            18,
                          ),
                          itemCount: filtered.length + 2,
                          itemBuilder: (context, index) {
                            if (index == filtered.length + 1) {
                              return window?.hasMoreAfter == true
                                  ? Center(
                                      child: TextButton.icon(
                                        key: const ValueKey(
                                          'load-later-messages',
                                        ),
                                        onPressed: s.loadingMessageWindow
                                            ? null
                                            : _laterMessages,
                                        icon: const Icon(
                                          Icons.keyboard_arrow_down,
                                        ),
                                        label: Text(
                                          s.loadingMessageWindow
                                              ? '正在读取…'
                                              : '继续阅读后续消息',
                                        ),
                                      ),
                                    )
                                  : const SizedBox(height: 8);
                            }
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
                            final actionIdentity = _identity;
                            final alignRight =
                                own &&
                                s.settings['message_alignment'] != 'left';
                            final retracted = m['retracted_at'] != null;
                            if (retracted) {
                              return Padding(
                                key: _messageKeys.putIfAbsent(
                                  str(m['id']),
                                  GlobalKey.new,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Center(
                                  child: Text(
                                    '${officeDisplayName(author)} 撤回了一条消息',
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
                            final menu = IconButton(
                              padding: EdgeInsets.zero,
                              iconSize: 17,
                              tooltip: '消息操作',
                              onPressed: () => _openMessageActions(m),
                              icon: const Icon(Icons.more_horiz),
                            );
                            return _selectionWrapper(
                              m,
                              OfficeMessageActionRegion(
                                key: ValueKey('message-actions-${m['id']}'),
                                onOpen: (position) =>
                                    _openMessageActions(m, position),
                                child: Column(
                                  key: _messageKeys.putIfAbsent(
                                    str(m['id']),
                                    GlobalKey.new,
                                  ),
                                  children: [
                                    if (m['seq'] == window?.entryFirstUnreadSeq)
                                      Padding(
                                        key: const ValueKey(
                                          'first-unread-divider',
                                        ),
                                        padding: const EdgeInsets.only(
                                          bottom: 18,
                                        ),
                                        child: Row(
                                          children: [
                                            const Expanded(child: Divider()),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                  ),
                                              child: Text(
                                                '以下为未读消息 · ${window?.entryUnreadCount ?? 0} 条',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: accentColor,
                                                ),
                                              ),
                                            ),
                                            const Expanded(child: Divider()),
                                          ],
                                        ),
                                      ),
                                    if (index == 0 ||
                                        clockText(
                                              filtered[index - 1]['at'],
                                              date: true,
                                              context: context,
                                            ) !=
                                            clockText(
                                              m['at'],
                                              date: true,
                                              context: context,
                                            ))
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 4,
                                          bottom: 18,
                                        ),
                                        child: Text(
                                          clockText(
                                            m['at'],
                                            date: true,
                                            context: context,
                                          ),
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: Color(0xffb2b6bd),
                                          ),
                                        ),
                                      ),
                                    MouseRegion(
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 18,
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment: alignRight
                                              ? MainAxisAlignment.end
                                              : MainAxisAlignment.start,
                                          children: [
                                            if (!alignRight) ...[
                                              PersonAvatar(
                                                name: officeDisplayName(author),
                                                agent:
                                                    author['kind'] == 'agent',
                                                size: 32,
                                              ),
                                              const SizedBox(width: 10),
                                            ],
                                            Flexible(
                                              child: OfficeMessageHoverTools(
                                                key: ValueKey(
                                                  'hover-$actionIdentity-${room['id']}-${m['id']}',
                                                ),
                                                messageId: str(m['id']),
                                                timestamp: str(m['at']),
                                                state: s,
                                                onOpenMore: (position) {
                                                  if (_identity ==
                                                          actionIdentity &&
                                                      s.selectedRoomId ==
                                                          room['id']) {
                                                    _openMessageActions(
                                                      m,
                                                      position,
                                                    );
                                                  }
                                                },
                                                enabled:
                                                    !widget.mobile &&
                                                    !_selectingMessages,
                                                onAction: (action) {
                                                  if (_identity !=
                                                          actionIdentity ||
                                                      s.selectedRoomId !=
                                                          room['id']) {
                                                    return;
                                                  }
                                                  if (action == 'more') {
                                                    _openMessageActions(m);
                                                  } else {
                                                    _messageAction(m, action);
                                                  }
                                                },
                                                child: ConstrainedBox(
                                                  constraints: BoxConstraints(
                                                    maxWidth: widget.mobile
                                                        ? MediaQuery.sizeOf(
                                                                context,
                                                              ).width *
                                                              .74
                                                        : 600,
                                                  ),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        alignRight
                                                        ? CrossAxisAlignment.end
                                                        : CrossAxisAlignment
                                                              .start,
                                                    children: [
                                                      Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Flexible(
                                                            child: Text(
                                                              officeDisplayName(
                                                                author,
                                                              ),
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                fontSize: 10,
                                                                color:
                                                                    mutedColor,
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 6,
                                                          ),
                                                          IdentityBadge(
                                                            agent:
                                                                author['kind'] ==
                                                                'agent',
                                                          ),
                                                        ],
                                                      ),
                                                      const SizedBox(height: 7),
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 13,
                                                              vertical: 10,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: own
                                                              ? const Color(
                                                                  0xffe8efff,
                                                                )
                                                              : const Color(
                                                                  0xfff4f5f7,
                                                                ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                7,
                                                              ),
                                                        ),
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            if (m['reply_to'] !=
                                                                null)
                                                              Container(
                                                                margin:
                                                                    const EdgeInsets.only(
                                                                      bottom: 8,
                                                                    ),
                                                                padding:
                                                                    const EdgeInsets.only(
                                                                      left: 9,
                                                                    ),
                                                                decoration: const BoxDecoration(
                                                                  border: Border(
                                                                    left: BorderSide(
                                                                      color: Color(
                                                                        0xffc2cbdc,
                                                                      ),
                                                                      width: 2,
                                                                    ),
                                                                  ),
                                                                ),
                                                                child: InkWell(
                                                                  onTap: () => _showPanel(
                                                                    () => showOfficeMessageOriginal(
                                                                      context,
                                                                      s,
                                                                      str(
                                                                        room['id'],
                                                                      ),
                                                                      str(
                                                                        m['reply_to'],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  child: Text(
                                                                    '回复 ${parent == null ? '更早消息' : officeDisplayName(Json.from(parent['author'] as Map? ?? {}))}：${parent?['retracted_at'] != null ? '这条消息已撤回' : str(parent?['content'], '点击查看原文')}',
                                                                    maxLines: 2,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                    style: const TextStyle(
                                                                      fontSize:
                                                                          10,
                                                                      color:
                                                                          mutedColor,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            if (m['forwarded_from']
                                                                is Map)
                                                              const Padding(
                                                                padding:
                                                                    EdgeInsets.only(
                                                                      bottom: 6,
                                                                    ),
                                                                child: Text(
                                                                  '已转发',
                                                                  style: TextStyle(
                                                                    fontSize:
                                                                        10,
                                                                    color:
                                                                        mutedColor,
                                                                  ),
                                                                ),
                                                              ),
                                                            if (m['kind'] ==
                                                                    'forward_bundle' &&
                                                                m['forward_bundle']
                                                                    is Map)
                                                              OfficeForwardBundleCard(
                                                                key: ValueKey(
                                                                  'forward-bundle-${m['id']}',
                                                                ),
                                                                state: s,
                                                                roomId: str(
                                                                  room['id'],
                                                                ),
                                                                message: m,
                                                              ),
                                                            if (str(
                                                              m['content'],
                                                            ).isNotEmpty)
                                                              _ConversationMessageBody(
                                                                key: ValueKey(
                                                                  'message-content-${m['id']}',
                                                                ),
                                                                message: m,
                                                                onOpenMessageMenu:
                                                                    widget
                                                                        .mobile
                                                                    ? null
                                                                    : (offset) {
                                                                        if (mounted &&
                                                                            !_selectingMessages &&
                                                                            _identity ==
                                                                                actionIdentity &&
                                                                            s.selectedRoomId ==
                                                                                room['id']) {
                                                                          _openMessageActions(
                                                                            m,
                                                                            offset,
                                                                          );
                                                                        }
                                                                      },
                                                                selectable:
                                                                    !widget
                                                                        .mobile,
                                                                onAction: (action) {
                                                                  if (s.selectedRoomId !=
                                                                          room['id'] ||
                                                                      viewIdentity !=
                                                                          _identity) {
                                                                    return;
                                                                  }
                                                                  if (action ==
                                                                      'menu') {
                                                                    _openMessageActions(
                                                                      m,
                                                                    );
                                                                  } else {
                                                                    _messageAction(
                                                                      m,
                                                                      action,
                                                                    );
                                                                  }
                                                                },
                                                                runs: maps(
                                                                  s.detail?['runs'],
                                                                ),
                                                                onRecords: (id) =>
                                                                    OfficeDialogs.run(
                                                                      context,
                                                                      s,
                                                                      id,
                                                                    ),
                                                              ),
                                                            ...maps(
                                                              m['attachments'],
                                                            ).map(
                                                              (
                                                                a,
                                                              ) => MessageAttachment(
                                                                key: ValueKey(
                                                                  a['id'],
                                                                ),
                                                                state: s,
                                                                attachment: {
                                                                  ...a,
                                                                  'room_id':
                                                                      a['room_id'] ??
                                                                      s.selectedRoomId,
                                                                },
                                                              ),
                                                            ),
                                                            if (m['mention_all'] ==
                                                                    true ||
                                                                (m['mentions']
                                                                            as List? ??
                                                                        [])
                                                                    .isNotEmpty)
                                                              Padding(
                                                                padding:
                                                                    const EdgeInsets.only(
                                                                      top: 7,
                                                                    ),
                                                                child: Wrap(
                                                                  spacing: 5,
                                                                  runSpacing: 4,
                                                                  children: [
                                                                    if (m['mention_all'] ==
                                                                        true)
                                                                      Chip(
                                                                        key: ValueKey(
                                                                          'message-mention-all-${m['id']}',
                                                                        ),
                                                                        label: const Text(
                                                                          '@所有人',
                                                                          style: TextStyle(
                                                                            fontSize:
                                                                                10,
                                                                            color:
                                                                                accentColor,
                                                                          ),
                                                                        ),
                                                                        visualDensity:
                                                                            VisualDensity.compact,
                                                                        backgroundColor:
                                                                            selectedColor,
                                                                        side: BorderSide
                                                                            .none,
                                                                      ),
                                                                    for (final id
                                                                        in (m['mentions']
                                                                                as List? ??
                                                                            []))
                                                                      Chip(
                                                                        key: ValueKey(
                                                                          'message-mention-${m['id']}-$id',
                                                                        ),
                                                                        label: Text(
                                                                          '@${_name(str(id))}',
                                                                          style: const TextStyle(
                                                                            fontSize:
                                                                                10,
                                                                            color:
                                                                                accentColor,
                                                                          ),
                                                                        ),
                                                                        visualDensity:
                                                                            VisualDensity.compact,
                                                                        backgroundColor:
                                                                            const Color(
                                                                              0xffeef2fa,
                                                                            ),
                                                                        side: BorderSide
                                                                            .none,
                                                                      ),
                                                                  ],
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                      ),
                                                      if (reactions.isNotEmpty)
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                top: 5,
                                                              ),
                                                          child: Wrap(
                                                            spacing: 5,
                                                            runSpacing: 4,
                                                            children: reactions
                                                                .entries
                                                                .where(
                                                                  (e) =>
                                                                      e.value
                                                                          is List &&
                                                                      (e.value
                                                                              as List)
                                                                          .isNotEmpty,
                                                                )
                                                                .map(
                                                                  (
                                                                    e,
                                                                  ) => InkWell(
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
                                                                      padding: const EdgeInsets.symmetric(
                                                                        horizontal:
                                                                            8,
                                                                        vertical:
                                                                            3,
                                                                      ),
                                                                      decoration: BoxDecoration(
                                                                        color:
                                                                            (e.value as List).contains(
                                                                              personId(
                                                                                s.me ?? {},
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
                                                                      child: Row(
                                                                        mainAxisSize:
                                                                            MainAxisSize.min,
                                                                        children: [
                                                                          OfficeEmojiGlyph(
                                                                            id: e.key,
                                                                            size:
                                                                                19,
                                                                          ),
                                                                          const SizedBox(
                                                                            width:
                                                                                4,
                                                                          ),
                                                                          Text(
                                                                            '${(e.value as List).length}',
                                                                            style: const TextStyle(
                                                                              fontSize: 10,
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                )
                                                                .toList(),
                                                          ),
                                                        ),
                                                      Wrap(
                                                        crossAxisAlignment:
                                                            WrapCrossAlignment
                                                                .center,
                                                        children: [
                                                          if (m['edited_at'] !=
                                                              null)
                                                            const Padding(
                                                              padding:
                                                                  EdgeInsets.only(
                                                                    top: 5,
                                                                  ),
                                                              child: Text(
                                                                '已编辑',
                                                                style: TextStyle(
                                                                  fontSize: 9,
                                                                  color:
                                                                      mutedColor,
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
                                                              child: OfficeMessageReceiptIndicator(
                                                                message: m,
                                                                roomKind: str(
                                                                  room['kind'],
                                                                ),
                                                                onOpen: () =>
                                                                    _messageAction(
                                                                      m,
                                                                      'read',
                                                                    ),
                                                              ),
                                                            ),
                                                          if (widget.mobile)
                                                            SizedBox(
                                                              width:
                                                                  widget.mobile
                                                                  ? 44
                                                                  : 28,
                                                              height:
                                                                  widget.mobile
                                                                  ? 44
                                                                  : 28,
                                                              child: menu,
                                                            ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (alignRight) ...[
                                              const SizedBox(width: 10),
                                              PersonAvatar(
                                                name: officeDisplayName(author),
                                                agent:
                                                    author['kind'] == 'agent',
                                                size: 32,
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (_awayFromBottom || window?.hasMoreAfter == true)
                  Positioned(
                    right: 14,
                    bottom: 12,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('jump-latest-messages'),
                      onPressed: s.loadingMessageWindow
                          ? null
                          : _latestMessages,
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      label: Text(
                        unreadRemaining > 0
                            ? '$unreadRemaining 条未读 · 到最新'
                            : '回到最新消息',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_selectingMessages) _selectionBar() else _composer(),
        ],
      ],
    );
  }

  Widget _composer() => RepaintBoundary(
    key: const ValueKey('conversation-composer-capture'),
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        widget.mobile ? 11 : 22,
        0,
        widget.mobile ? 11 : 22,
        widget.mobile ? 10 : 20,
      ),
      child: Container(
        key: const ValueKey('conversation-composer-frame'),
        padding: widget.mobile
            ? EdgeInsets.zero
            : const EdgeInsets.fromLTRB(12, 10.5, 11.5, 8.5),
        decoration: widget.mobile
            ? null
            : BoxDecoration(
                border: Border.all(
                  color: widget.mobile
                      ? const Color(0xffdce0e6)
                      : const Color(0xffdfdfe0),
                ),
                borderRadius: BorderRadius.circular(widget.mobile ? 9 : 8),
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                        '回复 ${officeDisplayName(Json.from(_reply!['author'] as Map? ?? {}))}：${(_reply!['retracted_at'] != null ? '这条消息已撤回' : str(_reply!['content']))}',
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
            if (_mentionAll || _mentions.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 5,
                  children: [
                    if (_mentionAll)
                      InputChip(
                        key: const ValueKey('composer-mention-all'),
                        label: const Text(
                          '@所有人',
                          style: TextStyle(fontSize: 10, color: accentColor),
                        ),
                        onDeleted: () {
                          setState(() => _mentionAll = false);
                          _saveDraft();
                        },
                        deleteIcon: const Icon(Icons.close, size: 13),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: selectedColor,
                        side: BorderSide.none,
                      ),
                    for (final id in _mentions)
                      InputChip(
                        key: ValueKey('composer-mention-$id'),
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
                  ],
                ),
              ),
            Container(
              key: const ValueKey('composer-input-surface'),
              padding: widget.mobile
                  ? const EdgeInsets.only(left: 10)
                  : EdgeInsets.zero,
              decoration: widget.mobile
                  ? BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    )
                  : null,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed &&
                            (s.settings['send_shortcut'] != 'mod_enter' ||
                                HardwareKeyboard.instance.isControlPressed ||
                                HardwareKeyboard.instance.isMetaPressed) &&
                            !(_input.value.composing.isValid &&
                                !_input.value.composing.isCollapsed)) {
                          _send();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        key: const ValueKey('composer-input'),
                        controller: _input,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: 7,
                        maxLength: 12000,
                        textInputAction: widget.mobile
                            ? TextInputAction.send
                            : null,
                        // Keep the composing range until the submitted action
                        // has been checked; the default completion clears it.
                        onEditingComplete: widget.mobile ? () {} : null,
                        onSubmitted: widget.mobile
                            ? _submitMobileComposer
                            : null,
                        style: const TextStyle(fontSize: 13, height: 1.7),
                        decoration: InputDecoration(
                          hintText:
                              '发送给 ${str(_selectedRoom?['name'], '当前会话')}',
                          hintStyle: widget.mobile
                              ? null
                              : const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w300,
                                  color: Color(0xff929494),
                                ),
                          isDense: true,
                          constraints: BoxConstraints(
                            minHeight: widget.mobile ? 40 : 31,
                          ),
                          filled: false,
                          counterText: '',
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.fromLTRB(
                            0,
                            widget.mobile ? 3 : 5,
                            0,
                            3,
                          ),
                        ),
                        onChanged: _inputChanged,
                        onTap: () {
                          if (_moreTools) setState(() => _moreTools = false);
                        },
                      ),
                    ),
                  ),
                  if (widget.mobile)
                    IconButton(
                      tooltip: '展开消息编辑器',
                      onPressed: _expandComposer,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 40,
                      ),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(32, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Transform.flip(
                        flipX: true,
                        child: const Icon(
                          CupertinoIcons.arrow_up_left_arrow_down_right,
                          size: 16,
                        ),
                      ),
                    ),
                ],
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
            if (!widget.mobile)
              _desktopComposerTools()
            else
              _mobileComposerTools(),
            if (widget.mobile && _moreTools) _mobileTools(),
          ],
        ),
      ),
    ),
  );

  void _formatInline(String style) {
    try {
      setState(
        () => _input.richText = officeToggleRichTextStyle(
          _input.text,
          _richText,
          _input.selection,
          style,
        ),
      );
      _saveDraft();
      _focus.requestFocus();
    } catch (error) {
      notifyOffice(context, friendlyError(error));
    }
  }

  void _insertComposerList(bool numbered) {
    final selection = _input.selection;
    if (!selection.isValid) return;
    final start =
        _input.text.lastIndexOf(
          '\n',
          selection.start > 0 ? selection.start - 1 : 0,
        ) +
        1;
    final prefix = numbered ? '1. ' : '• ';
    _input.value = TextEditingValue(
      text: _input.text.replaceRange(start, start, prefix),
      selection: TextSelection.collapsed(offset: selection.end + prefix.length),
    );
    _saveDraft();
    _focus.requestFocus();
    setState(() {});
  }

  Widget _mobileComposerTools() => ValueListenableBuilder<TextEditingValue>(
    valueListenable: _input,
    builder: (_, value, _) => Container(
      key: const ValueKey('mobile-composer-tools'),
      height: 44,
      margin: const EdgeInsets.only(top: 2),
      color: const Color(0xfff5f6f7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_mobileFormatting) ...[
            _composerIcon(
              'composer-format-close',
              '收起文字格式',
              Icons.keyboard_arrow_down,
              () => setState(() => _mobileFormatting = false),
            ),
            for (final action in [
              ('bold', '加粗', Icons.format_bold),
              ('strikethrough', '删除线', Icons.format_strikethrough),
              ('italic', '斜体', Icons.format_italic),
              ('underline', '下划线', Icons.format_underlined),
            ])
              _composerIcon(
                'composer-inline-${action.$1}',
                action.$2,
                action.$3,
                value.selection.isValid && !value.selection.isCollapsed
                    ? () => _formatInline(action.$1)
                    : null,
              ),
            _composerIcon(
              'composer-list-numbered',
              '编号列表',
              Icons.format_list_numbered,
              value.selection.isValid ? () => _insertComposerList(true) : null,
            ),
            _composerIcon(
              'composer-list-bullet',
              '项目列表',
              Icons.format_list_bulleted,
              value.selection.isValid ? () => _insertComposerList(false) : null,
            ),
          ] else ...[
            _composerIcon(
              'composer-emoji',
              '插入表情',
              Icons.sentiment_satisfied_alt_outlined,
              _chooseComposerEmoji,
            ),
            _composerIcon(
              'composer-mention',
              '提及成员',
              Icons.alternate_email,
              _mention,
            ),
            _composerIcon('composer-voice', '语音消息（尚未接入）', Icons.mic_none, null),
            _composerIcon(
              'composer-images',
              '选择图片或文件',
              Icons.image_outlined,
              _attachments.length < 8 ? _pickAttachments : null,
            ),
            SizedBox(
              width: 30,
              height: 30,
              child: Tooltip(
                message: '文字排版',
                child: TextButton(
                  key: const ValueKey('composer-format'),
                  onPressed: () => setState(() {
                    _mobileFormatting = true;
                    _moreTools = false;
                  }),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(30, 30),
                    foregroundColor: const Color(0xff6b7378),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Aa',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w400),
                  ),
                ),
              ),
            ),
            _composerIcon(
              'composer-agent',
              'Agent 协作',
              Icons.auto_awesome_outlined,
              _openComposerAgent,
              color: accentColor,
            ),
            _composerIcon(
              'composer-more',
              _moreTools ? '收起更多工具' : '更多工作工具',
              _moreTools ? Icons.close : Icons.add_circle_outline,
              () {
                _focus.unfocus();
                setState(() => _moreTools = !_moreTools);
              },
            ),
          ],
        ],
      ),
    ),
  );

  void _submitMobileComposer(String _) {
    final composing = _input.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    _send();
  }

  bool get _canSendDraft =>
      !_sending &&
      s.connected &&
      s.me != null &&
      (_input.text.trim().isNotEmpty || _attachments.isNotEmpty) &&
      !_attachments.any((item) => item.uploading || item.record == null);

  Future<void> _chooseComposerEmoji() async {
    final identity = _identity, roomId = s.selectedRoomId;
    final emoji = await _showPanel(() => showOfficeEmojiPicker(context, s));
    if (emoji != null &&
        mounted &&
        identity == _identity &&
        roomId == s.selectedRoomId) {
      _insert(officeEmojiText(emoji));
    }
  }

  Future<List<String>?> _openComposerAgent({
    Future<bool> Function()? beforeNavigate,
    bool applyMentions = true,
  }) async {
    final identity = _identity, roomId = s.selectedRoomId;
    final mentioned = <String>{};
    Future<void>? navigation;
    bool currentScope() =>
        mounted && identity == _identity && roomId == s.selectedRoomId;
    Future<void> navigate(VoidCallback action) async {
      if (!currentScope()) return;
      if (beforeNavigate != null && !await beforeNavigate()) return;
      if (currentScope()) action();
    }

    await _showPanel(
      () => showAgentCollaboration(
        context,
        s,
        onMention: (ids) {
          if (!currentScope()) return;
          mentioned.addAll(ids.where((id) => id.isNotEmpty));
          if (applyMentions) {
            setState(() => _mentions = {..._mentions, ...mentioned}.toList());
            _saveDraft();
            _focus.requestFocus();
          }
        },
        onRecords: () {
          navigation = navigate(() => setState(() => _tab = 3));
        },
        onStore: widget.onAgentStore == null
            ? null
            : () => navigation = navigate(widget.onAgentStore!),
      ),
    );
    await navigation;
    return currentScope() && mentioned.isNotEmpty ? mentioned.toList() : null;
  }

  Future<void> _formatComposer() async {
    final identity = _identity, roomId = s.selectedRoomId, draftKey = _key;
    final result = await _showPanel(
      () => showOfficeRichTextEditor(
        context,
        content: _input.text,
        richText: _richText,
        state: s,
      ),
    );
    if (result == null ||
        !mounted ||
        identity != _identity ||
        roomId != s.selectedRoomId ||
        draftKey != _key) {
      return;
    }
    setState(() {
      _input.setRichValue(result);
    });
    _saveDraft();
    _focus.requestFocus();
  }

  Future<void> _captureComposerScreenshot({bool hideWindow = false}) async {
    if (_screenshotBusy ||
        !_screenshot.supported ||
        _attachments.length >= 8 ||
        s.selectedRoomId == null) {
      return;
    }
    final identity = _identity, roomId = s.selectedRoomId!, draftKey = _key;
    setState(() => _screenshotBusy = true);
    try {
      final capability = await _screenshot.capability();
      if (!mounted ||
          identity != _identity ||
          roomId != s.selectedRoomId ||
          draftKey != _key) {
        return;
      }
      if (capability.requiresPermission) {
        final granted = await _showPanel(() => _screenshot.requestPermission());
        if (!mounted ||
            identity != _identity ||
            roomId != s.selectedRoomId ||
            draftKey != _key) {
          return;
        }
        if (granted != true) {
          throw const OfficeScreenshotException(
            'permission_required',
            '请在系统设置中允许人机录制屏幕，再重新打开客户端后截图。',
          );
        }
      } else if (!capability.available) {
        throw OfficeScreenshotException('unavailable', capability.reason);
      }
      final shot = await _showPanel(
        () => _screenshot.capture(hideWindow: hideWindow),
      );
      if (!mounted ||
          identity != _identity ||
          roomId != s.selectedRoomId ||
          draftKey != _key ||
          shot == null) {
        return;
      }
      if (shot.bytes.isEmpty || shot.bytes.length > 12 * 1024 * 1024) {
        setState(() => _error = '截图需为 1 字节至 12 MB，请缩小截取区域。');
        return;
      }
      final pending = PendingOfficeAttachment(
        filename: shot.filename,
        bytes: shot.bytes,
        mimeType: shot.mimeType,
        roomId: roomId,
      );
      setState(() => _attachments.add(pending));
      _saveDraft();
      await _upload(pending);
    } catch (error) {
      if (mounted &&
          identity == _identity &&
          roomId == s.selectedRoomId &&
          draftKey == _key) {
        setState(
          () => _error = error is OfficeScreenshotException
              ? error.message
              : friendlyError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _screenshotBusy = false);
    }
  }

  Widget _composerIcon(
    String key,
    String tooltip,
    IconData icon,
    VoidCallback? onPressed, {
    Color? color,
    double width = 30,
    Widget? iconWidget,
  }) => SizedBox(
    width: width,
    height: 30,
    child: IconButton(
      key: ValueKey(key),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: iconWidget ?? Icon(icon, size: widget.mobile ? 27 : 19),
      style: IconButton.styleFrom(
        foregroundColor: color ?? const Color(0xff6b7378),
        disabledForegroundColor: const Color(0xffc3c7c8),
        padding: EdgeInsets.zero,
        minimumSize: Size(width, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
  );

  Widget _desktopComposerTools() {
    final identity = _identity, roomId = s.selectedRoomId;
    bool sameScope() =>
        mounted && identity == _identity && roomId == s.selectedRoomId;
    return SizedBox(
      key: const ValueKey('desktop-composer-tools'),
      height: 30,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: Tooltip(
                      message: '文字排版',
                      child: TextButton(
                        key: const ValueKey('composer-format'),
                        onPressed: _formatComposer,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(30, 30),
                          foregroundColor: const Color(0xff6b7378),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Aa',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _composerIcon(
                    'composer-emoji',
                    '插入表情',
                    Icons.sentiment_satisfied_alt_outlined,
                    _chooseComposerEmoji,
                  ),
                  _composerIcon(
                    'composer-mention',
                    '提及成员',
                    Icons.alternate_email,
                    _mention,
                  ),
                  _composerIcon(
                    'composer-screenshot',
                    _screenshot.supported ? '截图' : '截图（当前平台尚未接入）',
                    Icons.content_cut,
                    _screenshot.supported &&
                            !_screenshotBusy &&
                            _attachments.length < 8
                        ? () => _captureComposerScreenshot()
                        : null,
                    width: 25,
                  ),
                  SizedBox(
                    width: 13,
                    height: 30,
                    child: PopupMenuButton<String>(
                      key: const ValueKey('composer-screenshot-menu'),
                      tooltip: '截图选项',
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.expand_more,
                        size: 14,
                        color: Color(0xff6b7378),
                      ),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'capture',
                          enabled:
                              _screenshot.supported &&
                              !_screenshotBusy &&
                              _attachments.length < 8,
                          child: const Text('截取屏幕'),
                        ),
                        PopupMenuItem(
                          value: 'hide',
                          enabled:
                              _screenshot.supported &&
                              !_screenshotBusy &&
                              _attachments.length < 8,
                          child: const Text('截图时隐藏人机窗口'),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'upload',
                          enabled: _attachments.length < 8,
                          child: const Text('选择已截取的图片'),
                        ),
                      ],
                      onSelected: (value) {
                        if (!sameScope()) return;
                        if (value == 'upload') {
                          _pickAttachments();
                        } else {
                          _captureComposerScreenshot(
                            hideWindow: value == 'hide',
                          );
                        }
                      },
                    ),
                  ),
                  _composerIcon(
                    'composer-agent',
                    'Agent 协作',
                    Icons.auto_awesome_outlined,
                    _openComposerAgent,
                    color: accentColor,
                  ),
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: PopupMenuButton<String>(
                      key: const ValueKey('composer-more'),
                      tooltip: '更多工作工具',
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.add_circle_outline,
                        size: 20,
                        color: Color(0xff6b7378),
                      ),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'file',
                          enabled: _attachments.length < 8,
                          child: const _ComposerMenuItem(
                            Icons.attach_file,
                            '文件与图片',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'document',
                          enabled: s.moduleAvailable('docs'),
                          child: const _ComposerMenuItem(
                            Icons.description_outlined,
                            '新建共同文档',
                          ),
                        ),
                        PopupMenuItem(
                          value: 'task',
                          enabled: s.moduleAvailable('tasks'),
                          child: const _ComposerMenuItem(
                            Icons.add_task_outlined,
                            '创建任务',
                          ),
                        ),
                        if (widget.onCreateCalendar != null)
                          PopupMenuItem(
                            value: 'calendar',
                            enabled: s.moduleAvailable('calendar'),
                            child: const _ComposerMenuItem(
                              Icons.calendar_month_outlined,
                              '创建日程',
                            ),
                          ),
                        if (widget.onCreateMeeting != null)
                          PopupMenuItem(
                            value: 'meeting',
                            enabled: s.moduleAvailable('meetings'),
                            child: const _ComposerMenuItem(
                              Icons.videocam_outlined,
                              '发起会议',
                            ),
                          ),
                        PopupMenuItem(
                          value: 'records',
                          enabled: s.moduleAvailable('workbench'),
                          child: const _ComposerMenuItem(Icons.history, '工作记录'),
                        ),
                      ],
                      onSelected: (value) {
                        if (!sameScope()) return;
                        switch (value) {
                          case 'file':
                            _pickAttachments();
                          case 'document':
                            _showPanel(
                              () => OfficeDialogs.document(context, s),
                            );
                          case 'task':
                            _showPanel(() => OfficeDialogs.task(context, s));
                          case 'calendar':
                            widget.onCreateCalendar?.call();
                          case 'meeting':
                            widget.onCreateMeeting?.call();
                          case 'records':
                            setState(() => _tab = 3);
                        }
                      },
                    ),
                  ),
                  _composerIcon(
                    'composer-expand',
                    '展开消息编辑器',
                    Icons.open_in_full,
                    _expandComposer,
                    iconWidget: Transform.flip(
                      flipX: true,
                      child: const Icon(
                        CupertinoIcons.arrow_up_left_arrow_down_right,
                        size: 19,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _input,
            builder: (_, _, _) => _composerIcon(
              'composer-send',
              _sending ? '发送中' : '发送',
              Icons.send_rounded,
              _canSendDraft ? _send : null,
              color: accentColor,
              width: 32,
            ),
          ),
          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            color: const Color(0xffdedfe0),
          ),
          SizedBox(
            width: 18,
            height: 30,
            child: PopupMenuButton<String>(
              key: const ValueKey('composer-send-options'),
              tooltip: '发送方式',
              enabled: !_savingSendMode,
              padding: EdgeInsets.zero,
              icon: const Icon(
                Icons.expand_more,
                size: 14,
                color: Color(0xffa9aeb0),
              ),
              itemBuilder: (_) => [
                for (final mode in ['enter', 'mod_enter'])
                  CheckedPopupMenuItem(
                    value: mode,
                    checked: str(s.settings['send_shortcut'], 'enter') == mode,
                    child: Text(
                      mode == 'enter'
                          ? 'Enter 发送，Shift + Enter 换行'
                          : 'Ctrl / ⌘ + Enter 发送',
                    ),
                  ),
              ],
              onSelected: (value) async {
                if (!sameScope() ||
                    _savingSendMode ||
                    value == str(s.settings['send_shortcut'], 'enter')) {
                  return;
                }
                final revision = (s.settings['revision'] as num?)?.toInt() ?? 1;
                setState(() => _savingSendMode = true);
                try {
                  await s.saveSettings({
                    'send_shortcut': value,
                  }, baseRevision: revision);
                } catch (error) {
                  if (sameScope()) {
                    setState(() => _error = friendlyError(error));
                  }
                } finally {
                  if (mounted) setState(() => _savingSendMode = false);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _expandComposer() async {
    final identity = _identity, roomId = s.selectedRoomId, draftKey = _key;
    final openedMentions = _mentions.toSet();
    bool currentScope() =>
        mounted &&
        identity == _identity &&
        roomId == s.selectedRoomId &&
        draftKey == _key;
    final result = await _showPanel(
      () => showOfficeExpandedComposer(
        context,
        state: s,
        value: OfficeRichTextValue(content: _input.text, richText: _richText),
        title: _expandedTitle,
        mentions: [..._mentions],
        mentionAll: _mentionAll,
        mobile: widget.mobile,
        onPickAttachments: () async {
          if (currentScope()) await _pickAttachments();
        },
        attachmentNames: () => currentScope()
            ? _attachments.map((attachment) => attachment.filename).toList()
            : [],
        onAgent: (saveAndClose) => currentScope()
            ? _openComposerAgent(
                beforeNavigate: saveAndClose,
                applyMentions: false,
              )
            : Future.value(null),
      ),
    );
    if (result == null || !currentScope()) return;
    setState(() {
      _input.setRichValue(result.value);
      _expandedTitle = result.title;
      _mentions = {
        ...result.mentions,
        ..._mentions.where((id) => !openedMentions.contains(id)),
      }.toList();
      _mentionAll = !_direct && result.mentionAll;
    });
    _saveDraft();
    if (result.sendRequested) await _send();
  }

  Widget _mobileTools() {
    final tools = <(String, IconData, VoidCallback?)>[
      (
        '文件与图片',
        Icons.folder_open_outlined,
        _attachments.length >= 8 ? null : _pickAttachments,
      ),
      (
        '云文档',
        Icons.description_outlined,
        s.moduleAvailable('docs')
            ? () => OfficeDialogs.document(context, s)
            : null,
      ),
      (
        '任务',
        Icons.task_alt_outlined,
        s.moduleAvailable('tasks')
            ? () => OfficeDialogs.task(context, s)
            : null,
      ),
      if (widget.onCreateCalendar != null)
        (
          '日程',
          Icons.calendar_month_outlined,
          s.moduleAvailable('calendar') ? widget.onCreateCalendar : null,
        ),
      if (widget.onCreateMeeting != null)
        (
          '发起会议',
          Icons.videocam_outlined,
          s.moduleAvailable('meetings') ? widget.onCreateMeeting : null,
        ),
      (
        '工作记录',
        Icons.history,
        s.moduleAvailable('workbench') ? () => setState(() => _tab = 3) : null,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.05,
        children: tools
            .map(
              (tool) => TextButton(
                onPressed: tool.$3 == null
                    ? null
                    : () {
                        setState(() => _moreTools = false);
                        tool.$3!();
                      },
                style: TextButton.styleFrom(padding: const EdgeInsets.all(3)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: const Color(0xfff4f6fa),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        tool.$2,
                        color: tool.$3 == null ? mutedColor : accentColor,
                        size: 22,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(tool.$1, style: const TextStyle(fontSize: 10)),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _ComposerMenuItem extends StatelessWidget {
  const _ComposerMenuItem(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: mutedColor),
      const SizedBox(width: 10),
      Text(label),
    ],
  );
}

class _ConversationMessageBody extends StatelessWidget {
  const _ConversationMessageBody({
    super.key,
    required this.message,
    required this.runs,
    required this.onRecords,
    this.onAction,
    this.onOpenMessageMenu,
    this.selectable = true,
  });
  final Json message;
  final List<Json> runs;
  final void Function(String) onRecords;
  final ValueChanged<String>? onAction;
  final ValueChanged<Offset>? onOpenMessageMenu;
  final bool selectable;
  @override
  Widget build(BuildContext context) => message['rich_text'] is Map
      ? OfficeRichText(
          content: str(message['content']),
          richText: Json.from(message['rich_text'] as Map),
          selectable: selectable,
          style: const TextStyle(fontSize: 13, height: 1.7),
          onAction: onAction,
          onOpenMessageMenu: onOpenMessageMenu,
        )
      : AgentMessageContent(
          message: message,
          runs: runs,
          onRecords: onRecords,
          onAction: onAction,
          onOpenMessageMenu: onOpenMessageMenu,
          selectable: selectable,
        );
}
