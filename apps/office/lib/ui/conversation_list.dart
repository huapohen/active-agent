import 'package:flutter/material.dart';

import 'office_emoji.dart' show officeEmojiLabel;
import 'office_theme.dart';

String _conversationEmojiSummary(String content) =>
    content.replaceAllMapped(RegExp(r':(feishu:[A-Za-z0-9_-]+):'), (match) {
      final token = match.group(0)!;
      final label = officeEmojiLabel(token);
      return label == token ? token : '[$label]';
    });

bool officeRoomFolded(Json room) =>
    room['folded'] == true || (room['preferences'] as Map?)?['folded'] == true;

bool officeRoomMuted(Json room) =>
    ((room['preferences'] as Map?)?['muted'] as bool?) ?? room['muted'] == true;

bool officeRoomPinned(Json room) =>
    ((room['preferences'] as Map?)?['pinned'] as bool?) ??
    room['is_pinned'] == true;

/// Empty rooms may show their real creation time; never invent recent activity.
String? officeConversationActivityAt(Json room) {
  final last = room['last_message'] as Map?;
  final at = last == null || last.isEmpty ? room['created_at'] : last['at'];
  return at is String && DateTime.tryParse(at) != null ? at : null;
}

int officeUnreadCount(Json room) =>
    ((room['unread_count'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);

/// Alerts are distinct from unread history. Folded rooms keep their messages
/// and receipts, while contributing no primary navigation notification badge.
int officeNotificationCount(Json room) {
  if (officeRoomFolded(room)) return 0;
  if (room['notification_count'] case final num count) {
    return count.toInt().clamp(0, 1 << 30);
  }
  if (officeRoomMuted(room)) {
    return ((room['mention_count'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);
  }
  return officeUnreadCount(room);
}

/// Only a direct message sent by this identity with an explicit reader snapshot
/// can claim that the other party has read it. Legacy watermarks are insufficient.
bool officeDirectMessageRead(Json room, String? currentPrincipalId) {
  if (room['kind'] != 'direct' ||
      currentPrincipalId == null ||
      currentPrincipalId.isEmpty) {
    return false;
  }
  final message = room['last_message'] as Map? ?? {};
  if (message['author_id'] != currentPrincipalId ||
      message['retracted_at'] != null) {
    return false;
  }
  final receipt = message['receipt_summary'] as Map? ?? {};
  return receipt['known'] == true &&
      receipt['basis'] == 'explicit_read_ack' &&
      receipt['eligible_count'] == 1 &&
      receipt['read_count'] == 1 &&
      receipt['unread_count'] == 0 &&
      receipt['unknown_count'] == 0;
}

class OfficeConversationRow extends StatelessWidget {
  const OfficeConversationRow({
    super.key,
    required this.room,
    required this.onOpen,
    required this.menu,
    this.selected = false,
    this.preview = true,
    this.onContextMenu,
    this.onContextMenuAt,
    this.currentPrincipalId,
  });
  final Json room;
  final VoidCallback onOpen;
  final VoidCallback? onContextMenu;
  final ValueChanged<Rect>? onContextMenuAt;
  final Widget menu;
  final bool selected, preview;
  final String? currentPrincipalId;

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 760;
    final last = room['last_message'] as Map? ?? {};
    final unread = officeUnreadCount(room);
    final folded = officeRoomFolded(room);
    final quiet = folded || officeRoomMuted(room);
    final mentioned = (room['mention_count'] as num? ?? 0) > 0;
    final explicit = (room['explicit_mention_count'] as num? ?? 0) > 0;
    final read = officeDirectMessageRead(room, currentPrincipalId);
    final summary = !preview
        ? '消息预览已隐藏'
        : last['retracted_at'] != null
        ? '一条消息已撤回'
        : str(last['content'], str(room['description'], '开始共同协作'));
    void openContextMenu() {
      final at = onContextMenuAt;
      final box = context.findRenderObject();
      if (at != null && box is RenderBox && box.hasSize) {
        at(box.localToGlobal(Offset.zero) & box.size);
      } else {
        onContextMenu?.call();
      }
    }

    final hasContextMenu = onContextMenuAt != null || onContextMenu != null;
    return Padding(
      padding: EdgeInsets.only(bottom: mobile ? 0 : 3),
      child: Material(
        color: selected ? selectedColor : Colors.white,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onOpen,
          onLongPress: hasContextMenu ? openContextMenu : null,
          onSecondaryTap: hasContextMenu ? openContextMenu : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: mobile ? 10 : 12,
            ),
            child: Row(
              children: [
                Stack(
                  key: ValueKey('conversation-avatar-${room['id']}'),
                  clipBehavior: Clip.none,
                  children: [
                    PersonAvatar(
                      name: str(room['name']),
                      group: room['kind'] != 'direct',
                      size: mobile ? 48 : 39,
                    ),
                    if (unread > 0)
                      Positioned(
                        top: -5,
                        right: -6,
                        child: Semantics(
                          label: '$unread 条未读消息',
                          child: ExcludeSemantics(
                            child: Container(
                              key: ValueKey(
                                'conversation-unread-${room['id']}',
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 18,
                                minHeight: 18,
                              ),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: quiet
                                    ? const Color(0xffb9c0cc)
                                    : const Color(0xffed727a),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1.5,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${unread > 99 ? '99+' : unread}',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: mobile
                                      ? OfficeMobileType.caption
                                      : 9,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              str(room['name']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: mobile ? OfficeMobileType.title : 12,
                                height: mobile ? 1.3 : null,
                                fontWeight: mobile
                                    ? FontWeight.w400
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (officeRoomPinned(room))
                            const Tooltip(
                              message: '置顶聊天',
                              child: Icon(
                                Icons.push_pin,
                                size: 13,
                                color: accentColor,
                              ),
                            ),
                          const SizedBox(width: 6),
                          Text(
                            clockText(
                              officeConversationActivityAt(room),
                              context: context,
                            ),
                            key: ValueKey('conversation-time-${room['id']}'),
                            style: TextStyle(
                              fontSize: mobile ? OfficeMobileType.caption : 9,
                              color: mobile
                                  ? mutedColor
                                  : const Color(0xffb0b6c0),
                            ),
                          ),
                          if (!mobile)
                            SizedBox(width: 26, height: 24, child: menu),
                        ],
                      ),
                      SizedBox(height: mobile ? 4 : 7),
                      Row(
                        children: [
                          if (read)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Tooltip(
                                message: '对方已读',
                                child: Icon(
                                  Icons.check,
                                  key: ValueKey(
                                    'conversation-read-${room['id']}',
                                  ),
                                  size: 13,
                                  color: const Color(0xffed727a),
                                ),
                              ),
                            ),
                          if (mentioned)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Text(
                                explicit ? '[@你]' : '[@所有人]',
                                style: TextStyle(
                                  fontSize: mobile
                                      ? OfficeMobileType.secondary
                                      : 10,
                                  height: mobile ? 1.3 : null,
                                  color: accentColor,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              _conversationEmojiSummary(summary),
                              key: ValueKey(
                                'conversation-summary-${room['id']}',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: mobile
                                    ? OfficeMobileType.secondary
                                    : 10,
                                height: mobile ? 1.3 : null,
                                color: mobile
                                    ? mutedColor
                                    : const Color(0xff9ba2ae),
                              ),
                            ),
                          ),
                          if (folded)
                            const Tooltip(
                              message: '已折叠',
                              child: Icon(
                                Icons.unfold_less,
                                size: 14,
                                color: mutedColor,
                              ),
                            )
                          else if (quiet)
                            Icon(
                              Icons.notifications_off_outlined,
                              key: ValueKey('conversation-muted-${room['id']}'),
                              size: mobile ? 16 : 12,
                              color: mutedColor,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OfficeFoldedSummary extends StatelessWidget {
  const OfficeFoldedSummary({
    super.key,
    required this.rooms,
    required this.onOpen,
  });
  final List<Json> rooms;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final unreadRooms = rooms
        .where((room) => officeUnreadCount(room) > 0)
        .length;
    final mentions = rooms.any(
      (room) => (room['mention_count'] as num? ?? 0) > 0,
    );
    return Semantics(
      label: '折叠的会话，${rooms.length} 个会话',
      button: true,
      child: Material(
        color: Colors.white,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 39,
                  height: 39,
                  decoration: BoxDecoration(
                    color: const Color(0xfff0f2f7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.unfold_less,
                    color: Color(0xff7c88a2),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '折叠的会话',
                        style: TextStyle(
                          fontSize: officeFontSize(
                            context,
                            desktop: 12,
                            mobile: OfficeMobileType.title,
                          ),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '${mentions ? '[有人@你] ' : ''}${unreadRooms > 0 ? '$unreadRooms 个会话有新消息' : '共 ${rooms.length} 个会话'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: officeFontSize(
                            context,
                            desktop: 10,
                            mobile: OfficeMobileType.secondary,
                          ),
                          color: mutedColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (unreadRooms > 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(
                      Icons.circle,
                      size: 6,
                      color: Color(0xffb9c0cc),
                    ),
                  ),
                const Icon(Icons.chevron_right, size: 18, color: mutedColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OfficeFoldedConversations extends StatefulWidget {
  const OfficeFoldedConversations({
    super.key,
    required this.rooms,
    required this.onBack,
    required this.itemBuilder,
  });
  final List<Json> rooms;
  final VoidCallback onBack;
  final Widget Function(Json room) itemBuilder;
  @override
  State<OfficeFoldedConversations> createState() =>
      _OfficeFoldedConversationsState();
}

class _OfficeFoldedConversationsState extends State<OfficeFoldedConversations> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final filtered = widget.rooms
        .where(
          (room) =>
              str(room['name']).toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(5, 14, 14, 10),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回消息',
                onPressed: widget.onBack,
                icon: const Icon(Icons.chevron_left),
              ),
              const Expanded(
                child: Text(
                  '折叠的会话',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${widget.rooms.length}',
                style: const TextStyle(fontSize: 11, color: mutedColor),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索折叠的会话',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _query.isEmpty ? '暂无折叠会话\n移出折叠后，会话将回到消息列表。' : '没有匹配的折叠会话',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: mutedColor,
                        fontSize: 12,
                        height: 1.9,
                      ),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  children: filtered.map(widget.itemBuilder).toList(),
                ),
        ),
      ],
    );
  }
}
