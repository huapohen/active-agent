import 'package:flutter/material.dart';

import 'office_theme.dart';

bool officeRoomFolded(Json room) =>
    room['folded'] == true || (room['preferences'] as Map?)?['folded'] == true;

int officeUnreadCount(Json room) =>
    ((room['unread_count'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);

/// Alerts are distinct from unread history. Folded rooms keep their messages
/// and receipts, while contributing no primary navigation notification badge.
int officeNotificationCount(Json room) {
  if (officeRoomFolded(room)) return 0;
  if (room['notification_count'] case final num count) {
    return count.toInt().clamp(0, 1 << 30);
  }
  if (room['muted'] == true) {
    return ((room['mention_count'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);
  }
  return officeUnreadCount(room);
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
  });
  final Json room;
  final VoidCallback onOpen;
  final VoidCallback? onContextMenu;
  final Widget menu;
  final bool selected, preview;

  @override
  Widget build(BuildContext context) {
    final last = room['last_message'] as Map? ?? {};
    final unread = officeUnreadCount(room);
    final folded = officeRoomFolded(room);
    final quiet = folded || room['muted'] == true;
    final mentioned = (room['mention_count'] as num? ?? 0) > 0;
    final explicit = (room['explicit_mention_count'] as num? ?? 0) > 0;
    final summary = !preview
        ? '消息预览已隐藏'
        : last['retracted_at'] != null
        ? '一条消息已撤回'
        : str(last['content'], str(room['description'], '开始共同协作'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? selectedColor : Colors.white,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onOpen,
          onLongPress: onContextMenu,
          onSecondaryTap: onContextMenu,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Row(
              children: [
                PersonAvatar(
                  name: str(room['name']),
                  group: room['kind'] != 'direct',
                  size: 39,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              str(room['name']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (room['is_pinned'] == true)
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
                            clockText(last['at'], context: context),
                            style: const TextStyle(
                              fontSize: 9,
                              color: Color(0xffb0b6c0),
                            ),
                          ),
                          SizedBox(width: 26, height: 24, child: menu),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          if (mentioned)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Text(
                                explicit ? '[@你]' : '[@所有人]',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: accentColor,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xff9ba2ae),
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
                            const Icon(
                              Icons.notifications_off_outlined,
                              size: 12,
                              color: mutedColor,
                            ),
                          if (unread > 0)
                            Container(
                              margin: const EdgeInsets.only(left: 5),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: quiet
                                    ? const Color(0xffb9c0cc)
                                    : const Color(0xffed727a),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                '${unread > 99 ? '99+' : unread}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                ),
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
                      const Text(
                        '折叠的会话',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '${mentions ? '[有人@你] ' : ''}${unreadRooms > 0 ? '$unreadRooms 个会话有新消息' : '共 ${rooms.length} 个会话'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: mutedColor),
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
