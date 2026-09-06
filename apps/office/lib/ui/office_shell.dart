import 'dart:async';

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import '../meeting_controller.dart';
import 'app_workbench.dart';
import 'calendar.dart';
import 'conversation.dart';
import 'meetings.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'people.dart';
import 'work_collections.dart';

class OfficeShell extends StatefulWidget {
  const OfficeShell({super.key, required this.state});
  final OfficeState state;
  @override
  State<OfficeShell> createState() => _OfficeShellState();
}

class _OfficeShellState extends State<OfficeShell> {
  int _nav = 0;
  bool _roomOpen = false, _unreadOnly = false;
  String _roomQuery = '', _globalQuery = '';
  Timer? _searchTimer;
  final MeetingMediaController _media = MeetingMediaController();
  OfficeState get s => widget.state;
  static const _labels = [
    '消息',
    'Agent',
    '通讯录',
    '云文档',
    '任务',
    '工作台',
    '视频会议',
    '日历',
  ];
  static const _icons = [
    Icons.chat_bubble_outline,
    Icons.auto_awesome_outlined,
    Icons.contacts_outlined,
    Icons.folder_outlined,
    Icons.task_alt,
    Icons.grid_view_rounded,
    Icons.videocam_outlined,
    Icons.calendar_month_outlined,
  ];
  @override
  void initState() {
    super.initState();
    _media.addListener(_mediaChanged);
  }

  void _mediaChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _media.removeListener(_mediaChanged);
    _media.dispose();
    super.dispose();
  }

  void _changeNav(int value) {
    setState(() {
      _nav = value;
      _roomOpen = false;
      _globalQuery = '';
    });
    if (value == 5 || value == 6 || value == 7) {
      unawaited(
        s.refreshOffice().catchError((Object e) {
          if (mounted) notifyOffice(context, friendlyError(e));
        }),
      );
    }
  }

  void _openApp(String route) {
    final id = route.contains('#')
        ? route.split('#').last
        : route.split('/').last;
    final nav = const {
      'messages': 0,
      'agents': 1,
      'contacts': 2,
      'documents': 3,
      'docs': 3,
      'tasks': 4,
      'workbench': 5,
      'meetings': 6,
      'calendar': 7,
    }[id];
    if (nav != null) _changeNav(nav);
  }

  Future<void> _joinMeeting(String id) async {
    _changeNav(6);
    await _media.join(s, id);
  }

  Future<void> _open(String id) async {
    setState(() {
      _nav = 0;
      _roomOpen = true;
      _globalQuery = '';
    });
    try {
      await s.selectRoom(id);
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  void _search(String query) {
    setState(() => _globalQuery = query);
    _searchTimer?.cancel();
    if (query.trim().isEmpty) return;
    _searchTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        await s.search(query);
      } catch (e) {
        if (mounted) notifyOffice(context, friendlyError(e));
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mobile = constraints.maxWidth < 760;
      return Scaffold(
        body: SafeArea(
          child: mobile
              ? Column(
                  children: [
                    if (_media.activeMeeting != null && _nav != 6) _callStrip(),
                    Expanded(child: _mobile()),
                  ],
                )
              : Row(
                  children: [
                    _rail(),
                    if (_nav == 0)
                      Container(
                        width: constraints.maxWidth < 1050 ? 260 : 290,
                        margin: const EdgeInsets.fromLTRB(0, 10, 9, 10),
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: _roomList(),
                      ),
                    if (_nav == 3) _documentSidebar(),
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Material(
                          color: Colors.white,
                          child: _globalQuery.isNotEmpty
                              ? _searchResults()
                              : _main(false),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        bottomNavigationBar:
            mobile &&
                !(_roomOpen && _nav == 0) &&
                !(_nav == 6 && _media.activeMeeting != null)
            ? NavigationBar(
                height: 65,
                backgroundColor: Colors.white,
                indicatorColor: selectedColor,
                selectedIndex: [0, 3, 5, 6].contains(_nav)
                    ? [0, 3, 5, 6].indexOf(_nav)
                    : 4,
                onDestinationSelected: (index) =>
                    _changeNav([0, 3, 5, 6, 8][index]),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.chat_bubble_outline, size: 20),
                    label: '消息',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined, size: 20),
                    label: '云文档',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.grid_view_rounded, size: 20),
                    label: '工作台',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.videocam_outlined, size: 20),
                    label: '视频会议',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.more_horiz, size: 20),
                    label: '更多',
                  ),
                ],
              )
            : null,
      );
    },
  );
  Widget _rail() => SizedBox(
    width: 180,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(15, 21, 14, 15),
      child: Column(
        children: [
          Row(
            children: [
              PersonAvatar(
                name: str(s.me?['name']),
                agent: s.me?['kind'] == 'agent',
                size: 34,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '同席',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      str(s.me?['name']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9, color: mutedColor),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '创建与身份',
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.add_circle_outline,
                  size: 20,
                  color: Color(0xff818b9b),
                ),
                onSelected: (v) {
                  if (v == 'group') OfficeDialogs.createRoom(context, s);
                  if (v == 'agent') _changeNav(1);
                  if (v == 'logout') s.disconnect();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'group', child: Text('创建工作群')),
                  const PopupMenuItem(value: 'agent', child: Text('添加 Agent')),
                  const PopupMenuItem(value: 'logout', child: Text('退出当前身份')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 23),
          OfficeSearch(hint: '搜索', onChanged: _search),
          const SizedBox(height: 22),
          ...List.generate(
            _labels.length,
            (i) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: _nav == i ? const Color(0xffdde6fc) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: () => _changeNav(i),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _icons[i],
                          size: 19,
                          color: _nav == i
                              ? accentColor
                              : const Color(0xff626f87),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _labels[i],
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: _nav == i
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _nav == i
                                ? accentColor
                                : const Color(0xff43516b),
                          ),
                        ),
                        if (i == 0 &&
                            s.rooms.fold<int>(
                                  0,
                                  (a, r) =>
                                      a +
                                      ((r['unread_count'] as num?)?.toInt() ??
                                          0),
                                ) >
                                0) ...[
                          const Spacer(),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Color(0xfff56c6c),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          if (_media.activeMeeting != null && _nav != 6) _callStrip(),
          Row(
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: s.connected
                      ? const Color(0xff62b98c)
                      : const Color(0xffe5b775),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                s.connected ? '消息已同步' : '正在重新连接',
                style: const TextStyle(fontSize: 9, color: Color(0xff98a3b7)),
              ),
              const Spacer(),
              IconButton(
                onPressed: () async {
                  try {
                    await s.refresh();
                  } catch (e) {
                    if (mounted) notifyOffice(context, friendlyError(e));
                  }
                },
                tooltip: '刷新工作空间',
                icon: const Icon(Icons.refresh, size: 16),
                constraints: const BoxConstraints.tightFor(
                  width: 24,
                  height: 24,
                ),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'ACTIVE AGENT × DOC FREE',
              style: TextStyle(
                fontSize: 7,
                color: Color(0xff9da8bd),
                letterSpacing: .8,
              ),
            ),
          ),
        ],
      ),
    ),
  );
  Widget _mobile() {
    if (_nav == 0 && _roomOpen) {
      return Material(
        color: Colors.white,
        child: OfficeConversation(
          state: s,
          mobile: true,
          onBack: () => setState(() => _roomOpen = false),
        ),
      );
    }
    if (_globalQuery.isNotEmpty) {
      return Material(color: Colors.white, child: _searchResults());
    }
    return Material(
      color: Colors.white,
      child: _nav == 0 ? _roomList(mobile: true) : _main(true),
    );
  }

  Widget _main(bool mobile) {
    switch (_nav) {
      case 0:
        return OfficeConversation(state: s);
      case 1:
        return OfficePeople(
          key: const ValueKey('agents'),
          state: s,
          agent: true,
          onConversation: () => setState(() {
            _nav = 0;
            _roomOpen = true;
          }),
        );
      case 2:
        return OfficePeople(
          key: const ValueKey('humans'),
          state: s,
          agent: false,
          onConversation: () => setState(() {
            _nav = 0;
            _roomOpen = true;
          }),
        );
      case 3:
        return WorkDocuments(state: s);
      case 4:
        return WorkTaskLibrary(state: s);
      case 6:
        return OfficeMeetings(
          state: s,
          media: _media,
          onCalendar: () => _changeNav(7),
        );
      case 7:
        return OfficeCalendar(state: s, onMeeting: _joinMeeting);
      case 8:
        return _more();
      default:
        return OfficeAppWorkbench(state: s, onOpen: _openApp);
    }
  }

  Widget _more() => ListView(
    padding: const EdgeInsets.all(22),
    children: [
      Row(
        children: [
          PersonAvatar(
            name: str(s.me?['name']),
            agent: s.me?['kind'] == 'agent',
            size: 43,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  str(s.me?['name']),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '同席工作空间',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 28),
      ...[1, 2, 7, 4].map(
        (i) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_icons[i], color: accentColor),
          title: Text(_labels[i], style: const TextStyle(fontSize: 14)),
          trailing: const Icon(
            Icons.chevron_right,
            size: 19,
            color: mutedColor,
          ),
          onTap: () => _changeNav(i),
        ),
      ),
      if (_media.activeMeeting != null)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.videocam_outlined,
            color: Color(0xff42a775),
          ),
          title: const Text('返回正在进行的会议'),
          onTap: () => _changeNav(6),
        ),
      const Divider(height: 35),
      TextButton.icon(
        onPressed: s.disconnect,
        icon: const Icon(Icons.logout, size: 18),
        label: const Text('退出当前身份'),
      ),
    ],
  );
  Widget _callStrip() => Material(
    color: const Color(0xffe8f4ee),
    child: InkWell(
      onTap: () => _changeNav(6),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_outlined, size: 15, color: Color(0xff43a077)),
            SizedBox(width: 7),
            Text(
              '会议进行中 · 返回',
              style: TextStyle(fontSize: 10, color: Color(0xff438667)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _roomList({bool mobile = false}) {
    final favorites = s.rooms
        .where(
          (r) =>
              r['is_favorite'] == true ||
              (r['preferences'] as Map?)?['favorite'] == true,
        )
        .toList();
    final rooms = s.rooms
        .where(
          (r) =>
              str(r['name']).toLowerCase().contains(_roomQuery.toLowerCase()) &&
              (!_unreadOnly || ((r['unread_count'] as num?)?.toInt() ?? 0) > 0),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(19, mobile ? 20 : 22, 12, 15),
          child: Row(
            children: [
              if (mobile) ...[
                PersonAvatar(
                  name: str(s.me?['name']),
                  agent: s.me?['kind'] == 'agent',
                  size: 36,
                ),
                const SizedBox(width: 11),
              ],
              Expanded(
                child: mobile
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            str(s.me?['name']),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '同席工作空间',
                            style: TextStyle(fontSize: 10, color: mutedColor),
                          ),
                        ],
                      )
                    : const Text(
                        '消息',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              if (mobile)
                PopupMenuButton<String>(
                  tooltip: '当前身份',
                  icon: PersonAvatar(
                    name: str(s.me?['name']),
                    agent: s.me?['kind'] == 'agent',
                    size: 27,
                  ),
                  onSelected: (_) => s.disconnect(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'logout',
                      child: Text('${str(s.me?['name'])} · 退出'),
                    ),
                  ],
                ),
              IconButton(
                onPressed: () => setState(() => _unreadOnly = !_unreadOnly),
                tooltip: _unreadOnly ? '查看全部消息' : '仅看未读',
                icon: Icon(
                  Icons.filter_list,
                  color: _unreadOnly ? accentColor : mutedColor,
                  size: 19,
                ),
              ),
              IconButton(
                onPressed: () => OfficeDialogs.createRoom(context, s),
                tooltip: '创建工作群',
                icon: const Icon(Icons.add, size: 21),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
          child: OfficeSearch(
            hint: '搜索会话',
            onChanged: (q) => setState(() => _roomQuery = q),
          ),
        ),
        if (favorites.isNotEmpty)
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 17),
              itemCount: favorites.length,
              separatorBuilder: (_, _) => const SizedBox(width: 15),
              itemBuilder: (context, index) {
                final r = favorites[index];
                return InkWell(
                  onTap: () => _open(str(r['id'])),
                  child: SizedBox(
                    width: 43,
                    child: Column(
                      children: [
                        PersonAvatar(
                          name: str(r['name']),
                          group: r['kind'] != 'direct',
                          size: 36,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          str(r['name']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9,
                            color: mutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
          child: Row(
            children: [
              if (mobile) ...[
                ChoiceChip(
                  label: const Text('消息', style: TextStyle(fontSize: 11)),
                  selected: !_unreadOnly,
                  showCheckmark: false,
                  side: BorderSide.none,
                  onSelected: (_) => setState(() => _unreadOnly = false),
                ),
                const SizedBox(width: 9),
                ChoiceChip(
                  label: const Text('未读', style: TextStyle(fontSize: 11)),
                  selected: _unreadOnly,
                  showCheckmark: false,
                  side: BorderSide.none,
                  onSelected: (_) => setState(() => _unreadOnly = true),
                ),
                const Spacer(),
              ] else
                Text(
                  _unreadOnly ? '未读消息' : '全部会话',
                  style: const TextStyle(fontSize: 10, color: mutedColor),
                ),
              const SizedBox(width: 5),
              Text(
                '${rooms.length}',
                style: const TextStyle(fontSize: 9, color: Color(0xffb3bac7)),
              ),
            ],
          ),
        ),
        Expanded(
          child: rooms.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(23),
                  child: Center(
                    child: Text(
                      _unreadOnly ? '没有未读消息' : '还没有工作会话\n创建工作群，或从通讯录发起私聊。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        height: 1.9,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: rooms.length,
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  itemBuilder: (context, index) {
                    final r = rooms[index],
                        last = rooms[index]['last_message'] is Map
                            ? rooms[index]['last_message'] as Map
                            : {};
                    final unread = (r['unread_count'] as num?)?.toInt() ?? 0;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Material(
                        color: s.selectedRoomId == r['id'] && !mobile
                            ? selectedColor
                            : Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        child: InkWell(
                          onTap: () => _open(str(r['id'])),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                PersonAvatar(
                                  name: str(r['name']),
                                  group: r['kind'] != 'direct',
                                  size: 39,
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              str(r['name']),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            clockText(last['at']),
                                            style: const TextStyle(
                                              fontSize: 9,
                                              color: Color(0xffb0b6c0),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 7),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              last['retracted_at'] != null
                                                  ? '一条消息已撤回'
                                                  : str(
                                                      last['content'],
                                                      str(
                                                        r['description'],
                                                        '开始共同协作',
                                                      ),
                                                    ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: Color(0xff9bA2ae),
                                              ),
                                            ),
                                          ),
                                          if (r['muted'] == true)
                                            const Icon(
                                              Icons.notifications_off_outlined,
                                              size: 12,
                                              color: mutedColor,
                                            ),
                                          if (unread > 0)
                                            Container(
                                              margin: const EdgeInsets.only(
                                                left: 5,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 5,
                                                    vertical: 1,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: r['muted'] == true
                                                    ? const Color(0xffb9c0cc)
                                                    : const Color(0xffed727a),
                                                borderRadius:
                                                    BorderRadius.circular(9),
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
                  },
                ),
        ),
      ],
    );
  }

  Widget _documentSidebar() => Container(
    width: 230,
    margin: const EdgeInsets.fromLTRB(0, 10, 9, 10),
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 23),
    decoration: BoxDecoration(
      color: const Color(0xfff7f8fa),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 9),
          child: Text(
            '云文档',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: selectedColor,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Row(
            children: [
              Icon(Icons.home_outlined, size: 18, color: accentColor),
              SizedBox(width: 10),
              Text(
                '主页',
                style: TextStyle(
                  fontSize: 12,
                  color: accentColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        const Padding(
          padding: EdgeInsets.only(left: 10),
          child: Text(
            '工作会话中的文档',
            style: TextStyle(fontSize: 10, color: mutedColor),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            children: s.rooms
                .map(
                  (r) => Material(
                    color: Colors.transparent,
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 9),
                      leading: const Icon(
                        Icons.folder_outlined,
                        size: 17,
                        color: Color(0xffa9b3c6),
                      ),
                      minLeadingWidth: 10,
                      title: Text(
                        str(r['name']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: r['id'] == s.selectedRoomId
                              ? accentColor
                              : const Color(0xff727c8d),
                        ),
                      ),
                      onTap: () async {
                        try {
                          await s.selectRoom(str(r['id']));
                        } catch (e) {
                          if (mounted) notifyOffice(context, friendlyError(e));
                        }
                      },
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const Text(
          'Doc Free · 文档承载共同上下文',
          style: TextStyle(fontSize: 9, color: Color(0xffa5afc0)),
        ),
      ],
    ),
  );
  Widget _searchResults() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '搜索 “$_globalQuery”',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              onPressed: () => setState(() => _globalQuery = ''),
              tooltip: '关闭搜索',
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: s.searchResults.isEmpty
            ? const EmptyOffice(
                title: '没有找到匹配内容',
                subtitle: '搜索已加入会话中的消息、文档和任务。',
                icon: Icons.search,
              )
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: s.searchResults.length,
                separatorBuilder: (_, _) => const Divider(height: 20),
                itemBuilder: (context, index) {
                  final result = s.searchResults[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      result['type'] == 'document'
                          ? Icons.description_outlined
                          : result['type'] == 'task'
                          ? Icons.task_alt
                          : Icons.chat_bubble_outline,
                      color: accentColor,
                      size: 21,
                    ),
                    title: Text(
                      str(
                        result['title'],
                        result['type'] == 'message' ? '会话消息' : '工作内容',
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      str(result['content']),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        height: 1.8,
                      ),
                    ),
                    onTap: () async {
                      await _open(str(result['room_id']));
                      if (result['type'] == 'document' && context.mounted) {
                        final document = maps(s.detail?['documents'])
                            .where((d) => d['id'] == result['id'])
                            .firstOrNull;
                        if (document != null) {
                          OfficeDialogs.document(context, s, document);
                        }
                      }
                    },
                  );
                },
              ),
      ),
    ],
  );
}
