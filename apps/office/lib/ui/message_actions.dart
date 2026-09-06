import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'emoji_assets.dart';
import 'office_theme.dart';
import 'office_emoji.dart';

const officeQuickReactions = [
  'feishu:THUMBSUP',
  'feishu:HEART',
  'feishu:APPLAUSE',
  'feishu:THANKS',
  'feishu:DONE',
  'feishu:SMILE',
];

List<(String, String, IconData)> officeMessageActions(Json message, bool own) {
  final live = message['retracted_at'] == null;
  final marked =
      message['personal_preferences'] is Map &&
      message['personal_preferences']['marked'] == true;
  return [
    if (live) ...[
      ('emoji', '表情回应', Icons.add_reaction_outlined),
      ('reply', '回复', Icons.reply_outlined),
      ('forward', '转发', Icons.forward_outlined),
      ('topic', '创建话题', Icons.forum_outlined),
      if (str(message['content']).isNotEmpty)
        ('copy', '复制', Icons.copy_outlined),
      if (str(message['content']).isNotEmpty)
        ('select', '选择文本', Icons.text_fields),
      ('agent', 'Agent 协作', Icons.auto_awesome),
      if (own) ('urgency', '加急', Icons.bolt_outlined),
      ('multi_select', '多选', Icons.checklist_outlined),
      ('mark', marked ? '取消标记' : '标记', Icons.bookmark_border),
    ],
    ('copy_link', '复制消息链接', Icons.link),
    if (live) ...[
      (
        'pin',
        message['pinned'] == true ? '取消 Pin' : 'Pin',
        Icons.push_pin_outlined,
      ),
      ('highlight', '置顶消息', Icons.vertical_align_top),
      ('task', '创建任务', Icons.add_task),
    ],
    ('export', '导出消息', Icons.file_download_outlined),
    if (own && live) ...[
      (
        'forwarding',
        message['forwarding_own_no_forward'] == true ? '允许转发' : '禁止转发',
        Icons.lock_outline,
      ),
      ('edit', '编辑消息', Icons.edit_outlined),
    ],
    ('read', '阅读状态', Icons.done_all),
    ('original', '查看原文', Icons.article_outlined),
    ('hide', '删除消息（仅自己）', Icons.delete_outline),
    if (own && live) ('retract', '撤回消息', Icons.undo),
  ];
}

class _MessageActionSession extends ChangeNotifier {
  _MessageActionSession(this.state) {
    final s = state;
    if (s != null) {
      _identity = (
        s.identityGeneration,
        s.endpoint,
        personId(s.me ?? {}),
        s.selectedRoomId,
      );
      s.addListener(_changed);
      unawaited(_loadRecents());
    }
  }
  final OfficeState? state;
  (int, String, String, String?)? _identity;
  bool _expired = false, _disposed = false;
  List<String> quick = [...officeQuickReactions];
  bool get current {
    final s = state;
    return !_disposed &&
        !_expired &&
        (s == null ||
            s.me != null &&
                _identity ==
                    (
                      s.identityGeneration,
                      s.endpoint,
                      personId(s.me ?? {}),
                      s.selectedRoomId,
                    ));
  }

  void _changed() {
    if (_disposed) return;
    if (!current) {
      _expired = true;
      quick = [];
    }
    notifyListeners();
  }

  Future<void> _loadRecents() async {
    final s = state;
    if (s == null || !s.connected || !current) return;
    try {
      final response = await s.officeRequest('/emoji/recents');
      if (!current) return;
      final recent = (response['emoji_ids'] as List? ?? [])
          .whereType<String>()
          .where(
            (id) =>
                id.isNotEmpty &&
                id.length <= 128 &&
                (!id.startsWith('feishu:') ||
                    officeClassicEmoji.containsKey(id)),
          );
      quick = {...recent, ...officeQuickReactions}.take(6).toList();
      notifyListeners();
    } catch (_) {
      // The bundled six remain usable when personal recents are unavailable.
    }
  }

  void record(String id) {
    final s = state;
    if (s == null || !s.connected || !current) return;
    // Choosing a reaction must not wait for a best-effort recent-list write.
    unawaited(
      s
          .officeRequest('/emoji/recents', method: 'POST', data: {'emoji': id})
          .then<void>((_) {}, onError: (_) {}),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    state?.removeListener(_changed);
    super.dispose();
  }
}

bool _actionEnabled(Json message, String action) =>
    action != 'forward' || message['no_forward'] != true;

Widget _quickReactions(
  BuildContext context,
  _MessageActionSession session, {
  bool desktop = false,
}) => AnimatedBuilder(
  animation: session,
  builder: (context, _) => !session.current
      ? const SizedBox.shrink()
      : SizedBox(
          height: desktop ? 40 : 50,
          child: Row(
            children: [
              for (final emoji in session.quick)
                Expanded(
                  child: IconButton(
                    key: ValueKey('message-quick-$emoji'),
                    tooltip: '回应 ${officeEmojiLabel(emoji)}',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 34,
                      height: 40,
                    ),
                    onPressed: () {
                      if (session.current) {
                        Navigator.pop(context, 'react:$emoji');
                      }
                    },
                    icon: OfficeEmojiGlyph(id: emoji, size: desktop ? 25 : 28),
                  ),
                ),
              Expanded(
                child: IconButton(
                  key: const ValueKey('message-more-emoji'),
                  tooltip: '全部表情',
                  onPressed: () {
                    if (session.current) Navigator.pop(context, 'emoji');
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 40,
                  ),
                  icon: const Icon(Icons.more_horiz, size: 24),
                ),
              ),
            ],
          ),
        ),
);

const _primaryActions = ['reply', 'forward', 'topic', 'copy'];
List<List<(String, String, IconData)>> _mobileActionGroups(
  List<(String, String, IconData)> actions,
) {
  final byId = {for (final action in actions) action.$1: action};
  return [
    for (final ids in const [
      ['retract', 'urgency', 'multi_select'],
      ['mark'],
      ['pin', 'highlight', 'copy_link', 'forwarding'],
      ['select', 'edit', 'agent', 'task', 'export', 'read', 'original'],
      ['hide'],
    ])
      [
        for (final id in ids)
          if (byId[id] != null) byId[id]!,
      ],
  ].where((group) => group.isNotEmpty).toList();
}

class _MobileMessageActions extends StatelessWidget {
  const _MobileMessageActions({
    required this.message,
    required this.actions,
    required this.session,
  });
  final Json message;
  final List<(String, String, IconData)> actions;
  final _MessageActionSession session;
  @override
  Widget build(BuildContext context) {
    final groups = _mobileActionGroups(actions);
    return DraggableScrollableSheet(
      key: const ValueKey('message-actions-draggable-sheet'),
      initialChildSize: .45,
      minChildSize: .45,
      maxChildSize: .85,
      expand: false,
      snap: true,
      snapSizes: const [.45, .85],
      shouldCloseOnMinExtent: false,
      builder: (context, controller) => SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: session,
          builder: (context, _) => !session.current
              ? const Center(child: Text('工作身份或会话已变化，请重新打开消息操作。'))
              : SingleChildScrollView(
                  key: const ValueKey('message-actions-scroll'),
                  controller: controller,
                  physics: const ClampingScrollPhysics(),
                  child: Column(
                    children: [
                      SizedBox(
                        key: const ValueKey('message-actions-drag-handle'),
                        height: 26,
                        width: double.infinity,
                        child: Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: const Color(0xffc9cdd3),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                      if (message['retracted_at'] == null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: _quickReactions(context, session),
                        ),
                        const Divider(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            key: const ValueKey('message-actions-primary'),
                            children: [
                              for (final id in _primaryActions)
                                Expanded(child: _primary(context, id)),
                            ],
                          ),
                        ),
                        const Divider(height: 16),
                      ],
                      for (var group = 0; group < groups.length; group++) ...[
                        if (group > 0) const Divider(height: 12),
                        for (final action in groups[group])
                          ListTile(
                            key: ValueKey('message-action-${action.$1}'),
                            dense: true,
                            visualDensity: const VisualDensity(vertical: -1),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 22,
                            ),
                            minLeadingWidth: 24,
                            leading: Icon(
                              action.$3,
                              size: 21,
                              color:
                                  action.$1 == 'retract' || action.$1 == 'hide'
                                  ? Colors.redAccent
                                  : action.$1 == 'agent'
                                  ? accentColor
                                  : const Color(0xff454b55),
                            ),
                            title: Text(
                              action.$2,
                              style: TextStyle(
                                fontSize: 14,
                                color:
                                    action.$1 == 'retract' ||
                                        action.$1 == 'hide'
                                    ? Colors.redAccent
                                    : null,
                              ),
                            ),
                            onTap: () {
                              if (session.current) {
                                Navigator.pop(context, action.$1);
                              }
                            },
                          ),
                      ],
                      const Divider(height: 12),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _primary(BuildContext context, String id) {
    final item =
        actions.where((a) => a.$1 == id).firstOrNull ??
        ('copy', '复制', Icons.copy_outlined);
    final enabled =
        actions.any((a) => a.$1 == id) && _actionEnabled(message, id);
    final color = enabled ? const Color(0xff353b45) : mutedColor;
    return InkWell(
      key: ValueKey('message-action-$id'),
      onTap: !enabled
          ? null
          : () {
              if (session.current) Navigator.pop(context, id);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            Icon(item.$3, size: 24, color: color),
            const SizedBox(height: 7),
            Text(
              item.$2,
              style: TextStyle(fontSize: 12, color: color),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> showOfficeMessageActions(
  BuildContext context,
  Json message, {
  required bool own,
  Offset? position,
  OfficeState? state,
}) async {
  final actions = officeMessageActions(message, own);
  final session = _MessageActionSession(state);
  try {
    String? result;
    if (MediaQuery.sizeOf(context).width < 720) {
      result = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        enableDrag: false,
        useSafeArea: true,
        builder: (context) => _MobileMessageActions(
          message: message,
          actions: actions,
          session: session,
        ),
      );
    } else {
      final overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final point =
          position ?? overlay.localToGlobal(overlay.size.center(Offset.zero));
      result = await showMenu<String>(
        context: context,
        constraints: const BoxConstraints(minWidth: 260, maxWidth: 300),
        position: RelativeRect.fromRect(
          Rect.fromPoints(
            overlay.globalToLocal(point),
            overlay.globalToLocal(point),
          ),
          Offset.zero & overlay.size,
        ),
        items: [
          if (message['retracted_at'] == null) ...[
            PopupMenuItem<String>(
              enabled: false,
              height: 44,
              child: _quickReactions(context, session, desktop: true),
            ),
            const PopupMenuDivider(),
          ],
          for (final item in actions) ...[
            if (['agent', 'mark', 'forwarding', 'hide'].contains(item.$1))
              const PopupMenuDivider(),
            PopupMenuItem(
              key: ValueKey('message-action-${item.$1}'),
              value: item.$1,
              enabled: _actionEnabled(message, item.$1),
              height: 32,
              child: Row(
                children: [
                  Icon(
                    item.$3,
                    size: 18,
                    color: item.$1 == 'agent'
                        ? accentColor
                        : item.$1 == 'retract' || item.$1 == 'hide'
                        ? Colors.redAccent
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(item.$2, style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    }
    if (!session.current) return null;
    if (result == 'emoji' && state != null && context.mounted) {
      final emoji = await showOfficeEmojiPicker(context, state);
      return session.current && emoji != null ? 'react:$emoji' : null;
    }
    if (result?.startsWith('react:') == true) {
      session.record(result!.substring(6));
    }
    return result;
  } finally {
    session.dispose();
  }
}

/// The same actions are available from pointer gestures and keyboard focus.
class OfficeMessageActionRegion extends StatelessWidget {
  const OfficeMessageActionRegion({
    super.key,
    required this.child,
    required this.onOpen,
  });
  final Widget child;
  final void Function(Offset? position) onOpen;
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.f10, shift: true): () =>
          onOpen(null),
      const SingleActivator(LogicalKeyboardKey.contextMenu): () => onOpen(null),
    },
    child: Focus(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (details) => onOpen(details.globalPosition),
        onSecondaryTapDown: (details) => onOpen(details.globalPosition),
        child: child,
      ),
    ),
  );
}
