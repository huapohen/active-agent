import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import '../message_groups.dart';
import '../meeting_controller.dart';
import 'workbench_navigation.dart';
import 'desktop_navigation.dart';
import 'mobile_more_menu.dart';
import 'approvals.dart';
import 'attendance.dart';
import 'business_widgets.dart';
import 'mailbox.dart';
import 'settings.dart';
import 'search_filters.dart';
import 'mobile_navigation.dart';
import 'profile_menu.dart';
import 'minutes.dart';
import 'message_group_widgets.dart';
import 'message_group_editor.dart';
import 'message_group_labels.dart';
import 'calendar.dart';
import 'conversation.dart';
import 'message_personal.dart';
import 'message_links.dart';
import 'conversation_list.dart';
import 'enterprise.dart';
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
  int _nav = 0, _settingsTab = -1;
  int _beforeSettingsNav = 0;
  bool _beforeSettingsRoomOpen = false;
  final _meetingsKey = GlobalKey<OfficeMeetingsState>();
  final _calendarKey = GlobalKey<OfficeCalendarState>();
  final _approvalsKey = GlobalKey<OfficeApprovalsState>();
  final _mailKey = GlobalKey<OfficeMailboxState>();
  final _minutesKey = GlobalKey<OfficeMinutesState>();
  OfficeMessageGroups? _groupsController;
  OfficeMessageGroups get _messageGroups {
    if (_groupsController case final existing?) return existing;
    final created = OfficeMessageGroups(s)..addListener(_groupsChanged);
    _groupsController = created;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(created.refresh());
    });
    return created;
  }

  bool _groupsOpen = false;
  bool _moreOpen = false;
  String? _moreIdentity;
  bool get _moreVisible => _moreOpen && _moreIdentity == _identityKey;
  void _closeMore() => setState(() => _moreOpen = false);
  void _toggleMore() => setState(() {
    _moreOpen = !_moreVisible;
    _moreIdentity = _identityKey;
  });
  bool _foldedOpen = false;
  final Set<String> _pendingRoomPreferences = {};
  String _searchType = 'all';
  bool _searchOpen = false, _agentStore = false;
  bool _roomOpen = false, _unreadOnly = false;
  String _roomQuery = '', _globalQuery = '';
  Timer? _searchTimer;
  final _globalSearchInput = TextEditingController();
  final _globalSearchFocus = FocusNode();
  final _searchScroll = ScrollController();
  OfficeSearchFilters _searchFilters = const OfficeSearchFilters();
  int _searchIntent = 0, _selectedSearchResult = -1;
  bool _searching = false;
  String? _searchError;
  final MeetingMediaController _media = MeetingMediaController();
  OfficeState get s => widget.state;
  List<int> get _mobileNav => [
    ...officeMobileNavigation(s).map((item) => item.route),
    12,
  ];
  List<OfficeNavigationItem> get _desktopNavigation => [
    ...officeDesktopNavigation(s),
    const OfficeNavigationItem('settings', '设置', Icons.settings_outlined, 11),
  ];
  @override
  void initState() {
    super.initState();
    _media.addListener(_mediaChanged);
    final target = officeMessageTarget(Uri.base);
    if (target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openMessageTarget(target.$1, target.$2));
      });
    }
  }

  void _groupsChanged() {
    if (mounted) {
      setState(() => _unreadOnly = _messageGroups.selectedId == 'unread');
    }
  }

  void _selectMessageGroup(String id) {
    setState(() {
      _unreadOnly = id == 'unread';
      _roomOpen = false;
      _foldedOpen = false;
    });
    _messageGroups.select(id);
  }

  Widget _groupPanel({BuildContext? drawerContext}) => OfficeMessageGroupPanel(
    controller: _messageGroups,
    onSelected: (id) {
      _selectMessageGroup(id);
      if (drawerContext != null) Navigator.pop(drawerContext);
    },
    onManage: () => showOfficeMessageGroupEditor(context, _messageGroups),
    onCreateLabel: () => showOfficeMessageLabelEditor(context, _messageGroups),
  );

  void _toggleGroups(bool mobile) {
    if (!_messageGroups.loaded) unawaited(_messageGroups.refresh());
    if (!mobile) {
      setState(() => _groupsOpen = !_groupsOpen);
      return;
    }
    showDialog<void>(
      context: context,
      barrierColor: Colors.black38,
      builder: (drawerContext) => Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: (MediaQuery.sizeOf(drawerContext).width * .78).clamp(240, 350),
          height: double.infinity,
          child: SafeArea(child: _groupPanel(drawerContext: drawerContext)),
        ),
      ),
    );
  }

  String get _identityKey =>
      '${identityHashCode(s)}|${s.identityGeneration}|${s.endpoint}|${personId(s.me ?? {})}';

  Future<void> _setRoomFolded(Json room, bool value, String identity) async {
    final id = str(room['id']);
    final operation = '$identity|$id';
    if (identity != _identityKey ||
        !s.connected ||
        _pendingRoomPreferences.contains(operation)) {
      return;
    }
    setState(() => _pendingRoomPreferences.add(operation));
    try {
      await s.officeRequest(
        '/rooms/${Uri.encodeComponent(id)}/preferences',
        method: 'PATCH',
        data: {'folded': value},
      );
      if (!mounted || identity != _identityKey) return;
      await s.refresh();
      if (mounted && identity == _identityKey) {
        notifyOffice(context, value ? '已移入折叠的会话' : '已移出折叠的会话');
      }
    } catch (error) {
      if (mounted && identity == _identityKey) {
        notifyOffice(context, friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _pendingRoomPreferences.remove(operation));
    }
  }

  Widget _roomGroupingMenu(Json room) {
    final identity = _identityKey;
    final folded = officeRoomFolded(room);
    return PopupMenuButton<String>(
      key: ValueKey('room-menu-$identity-${room['id']}'),
      tooltip: '整理会话',
      enabled:
          s.connected &&
          !_pendingRoomPreferences.contains('$identity|${room['id']}'),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 190),
      icon: const Icon(Icons.more_horiz, size: 16, color: mutedColor),
      onSelected: (action) {
        if (identity != _identityKey) return;
        if (action == 'fold' || action == 'unfold') {
          unawaited(_setRoomFolded(room, action == 'fold', identity));
        } else {
          showOfficeRoomGrouping(context, _messageGroups, room);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'grouping',
          enabled: _messageGroups.loaded,
          child: const Text('标签、标记与已完成'),
        ),
        PopupMenuItem(
          value: folded ? 'unfold' : 'fold',
          child: Text(folded ? '移出折叠的会话' : '移入折叠的会话'),
        ),
      ],
    );
  }

  Widget _conversationRow(Json room, bool mobile) {
    final identity = _identityKey;
    return OfficeConversationRow(
      key: ValueKey('room-row-${room['id']}'),
      room: room,
      currentPrincipalId: personId(s.me ?? {}),
      preview: s.settings['show_message_preview'] != false,
      selected:
          s.selectedRoomId == room['id'] &&
          !mobile &&
          (!_foldedOpen || _roomOpen),
      onOpen: () {
        if (identity == _identityKey) _open(str(room['id']));
      },
      onContextMenu: _messageGroups.loaded
          ? () {
              if (identity == _identityKey) {
                showOfficeRoomGrouping(context, _messageGroups, room);
              }
            }
          : null,
      menu: _roomGroupingMenu(room),
    );
  }

  void _mediaChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _groupsController?.removeListener(_groupsChanged);
    _groupsController?.dispose();
    _searchTimer?.cancel();
    _globalSearchInput.dispose();
    _globalSearchFocus.dispose();
    _searchScroll.dispose();
    _media.removeListener(_mediaChanged);
    _media.dispose();
    super.dispose();
  }

  void _changeNav(int value) {
    if (value == 11 && _nav != 11) {
      _beforeSettingsNav = _nav;
      _beforeSettingsRoomOpen = _roomOpen;
    }
    _searchTimer?.cancel();
    _searchIntent++;
    _globalSearchInput.clear();
    setState(() {
      _moreOpen = false;
      _nav = value;
      _roomOpen = false;
      _globalQuery = '';
      _searchOpen = false;
    });
    if ([8, 9, 10, 11].contains(value)) {
      unawaited(
        s.refreshBusiness().catchError((Object e) {
          if (mounted) notifyOffice(context, friendlyError(e));
        }),
      );
    }
    if (value == 5 || value == 6 || value == 7) {
      unawaited(
        s.refreshOffice().catchError((Object e) {
          if (mounted) notifyOffice(context, friendlyError(e));
        }),
      );
    }
  }

  void _closeSettings() {
    _changeNav(_beforeSettingsNav);
    if (_beforeSettingsRoomOpen && s.selectedRoomId != null) {
      setState(() => _roomOpen = true);
    }
  }

  Widget _profileButton(Widget child) => Builder(
    builder: (context) => Tooltip(
      message: '我的与设置',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final endpoint = s.endpoint;
          final identity = personId(s.me ?? {});
          final generation = s.identityGeneration;
          final box = context.findRenderObject()! as RenderBox;
          final action = await showOfficeProfileMenu(
            context,
            s,
            anchor: box.localToGlobal(Offset.zero) & box.size,
          );
          if (!mounted ||
              s.endpoint != endpoint ||
              personId(s.me ?? {}) != identity ||
              s.identityGeneration != generation) {
            return;
          }
          switch (action) {
            case 'account':
              _settingsTab = 0;
              _changeNav(11);
            case 'settings':
              _settingsTab = -1;
              _changeNav(11);
            case 'workbench':
              _changeNav(5);
            case 'enterprise':
              if (s.canManageEnterprise) _changeNav(13);
            case 'logout':
              s.disconnect();
          }
        },
        child: Padding(padding: const EdgeInsets.all(2), child: child),
      ),
    ),
  );

  Future<void> _joinMeeting(String id) async {
    _changeNav(6);
    await _media.join(s, id);
  }

  Future<void> _open(String id) async {
    _searchTimer?.cancel();
    _searchIntent++;
    setState(() {
      _nav = 0;
      _roomOpen = true;
      _globalQuery = '';
      _searchOpen = false;
    });
    try {
      await s.selectRoom(id);
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  Future<void> _openMessageTarget(String roomId, String messageId) async {
    _searchTimer?.cancel();
    _searchIntent++;
    final identity = _identityKey;
    setState(() {
      _nav = 0;
      _roomOpen = true;
      _searchOpen = false;
      _globalQuery = '';
    });
    try {
      await s.focusMessage(roomId, messageId);
    } catch (error) {
      if (mounted && identity == _identityKey) {
        notifyOffice(context, friendlyError(error));
      }
    }
  }

  Future<void> _openMarkedMessages() async {
    final identity = _identityKey;
    final chosen = await showOfficePersonalMessages(context, s);
    if (chosen != null && mounted && identity == _identityKey) {
      await _openMessageTarget(
        str(chosen['room_id']),
        str((chosen['message'] as Map?)?['id']),
      );
    }
  }

  void _search(String query) {
    final intent = ++_searchIntent;
    if (_globalSearchInput.text != query) {
      _globalSearchInput.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    setState(() {
      _globalQuery = query;
      _searchOpen = true;
      _searching = query.trim().isNotEmpty;
      _selectedSearchResult = -1;
      _searchError = null;
    });
    _searchTimer?.cancel();
    if (query.trim().isEmpty) return;
    _searchTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        await s.search(
          query,
          type: _searchType,
          roomId: _searchFilters.roomId,
          authorId: _searchFilters.authorId,
          after: _searchFilters.after,
          before: _searchFilters.before,
        );
      } catch (e) {
        if (mounted && intent == _searchIntent) {
          _searchError = friendlyError(e);
        }
      } finally {
        if (mounted && intent == _searchIntent) {
          setState(() => _searching = false);
        }
      }
    });
  }

  void _closeSearch() {
    _searchTimer?.cancel();
    _searchIntent++;
    _globalSearchInput.clear();
    setState(() {
      _globalQuery = '';
      _searchOpen = false;
      _searching = false;
    });
  }

  void _focusSearch() {
    _search(_globalQuery);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen) _globalSearchFocus.requestFocus();
    });
  }

  void _moveSearchResult(int direction) {
    if (_searching || s.searchResults.isEmpty || _globalQuery.trim().isEmpty) {
      return;
    }
    setState(() {
      _selectedSearchResult = (_selectedSearchResult + direction).clamp(
        0,
        s.searchResults.length - 1,
      );
    });
    if (_searchScroll.hasClients) {
      final top = _selectedSearchResult * 104.0;
      final viewport = _searchScroll.position.viewportDimension;
      final offset = _searchScroll.offset;
      if (top < offset || top + 104 > offset + viewport) {
        _searchScroll.animateTo(
          (top < offset ? top : top + 104 - viewport).clamp(
            0,
            _searchScroll.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void _activateSearchResult() {
    if (_searching || s.searchResults.isEmpty || _globalQuery.trim().isEmpty) {
      return;
    }
    final index = _selectedSearchResult < 0 ? 0 : _selectedSearchResult;
    if (index < s.searchResults.length) {
      unawaited(_openSearchResult(s.searchResults[index]));
    }
  }

  Future<void> _filterSearch() async {
    final next = await showOfficeSearchFilters(
      context,
      s,
      type: _searchType,
      initial: _searchFilters,
    );
    if (next == null || !mounted) return;
    _searchFilters = next;
    _search(_globalQuery);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mobile = constraints.maxWidth < 760;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _focusSearch,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              _focusSearch,
          if (_moreVisible || _searchOpen)
            const SingleActivator(LogicalKeyboardKey.escape): _moreVisible
                ? _closeMore
                : _closeSearch,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: mobile
                  ? Column(
                      children: [
                        if (_media.activeMeeting != null && _nav != 6)
                          _callStrip(),
                        Expanded(
                          child: Stack(
                            children: [
                              ExcludeSemantics(
                                excluding: _moreVisible,
                                child: TickerMode(
                                  enabled: !_moreVisible,
                                  child: _mobile(),
                                ),
                              ),
                              if (_moreVisible)
                                OfficeMobileMoreMenu(
                                  key: ValueKey('mobile-more-$_identityKey'),
                                  onClose: _closeMore,
                                  child: _more(),
                                ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        _rail(),
                        if (_nav == 0 && s.moduleAvailable('im') && _groupsOpen)
                          Container(
                            width: 160,
                            margin: const EdgeInsets.fromLTRB(0, 10, 8, 10),
                            child: _groupPanel(),
                          ),
                        if (_nav == 0 && s.moduleAvailable('im'))
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
                        if (_nav == 3 && s.moduleAvailable('docs'))
                          _documentSidebar(),
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
                              child: _searchOpen
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
                    _nav != 11 &&
                    !(_roomOpen && _nav == 0) &&
                    !(_nav == 6 && _media.activeMeeting != null)
                ? NavigationBar(
                    height: 65,
                    backgroundColor: Colors.white,
                    indicatorColor: selectedColor,
                    selectedIndex: _moreVisible
                        ? _mobileNav.length - 1
                        : _mobileNav.contains(_nav)
                        ? _mobileNav.indexOf(_nav)
                        : _mobileNav.length - 1,
                    onDestinationSelected: (index) {
                      final route = _mobileNav[index];
                      route == 12 ? _toggleMore() : _changeNav(route);
                    },
                    destinations: [
                      for (final item in officeMobileNavigation(s))
                        NavigationDestination(
                          icon: Badge(
                            key: ValueKey('nav-badge-${item.id}'),
                            isLabelVisible:
                                item.route == 0 &&
                                s.rooms.any(
                                  (room) => officeNotificationCount(room) > 0,
                                ),
                            child: Icon(item.icon, size: 20),
                          ),
                          label: item.label,
                        ),
                      const NavigationDestination(
                        icon: Icon(Icons.more_horiz, size: 20),
                        label: '更多',
                      ),
                    ],
                  )
                : null,
          ),
        ),
      );
    },
  );
  void _desktopMenu(
    BuildContext itemContext,
    OfficeNavigationItem item, [
    Offset? position,
  ]) {
    final box = itemContext.findRenderObject() as RenderBox?;
    final anchor =
        position ??
        (box == null
            ? Offset.zero
            : box.localToGlobal(Offset(box.size.width, box.size.height / 2)));
    showOfficeDesktopNavigationMenu(
      context,
      s,
      item,
      position: anchor,
      onOpen: () => _changeNav(item.route),
    );
  }

  bool get _desktopCollapsed => s.settings['desktop_nav_collapsed'] == true;
  String? _collapsePendingIdentity;
  Future<void> _toggleDesktopNavigation() async {
    final identity = _identityKey;
    if (_collapsePendingIdentity == identity || !s.connected) return;
    final intended = !_desktopCollapsed;
    setState(() => _collapsePendingIdentity = identity);
    try {
      await s.saveSettings({
        'desktop_nav_collapsed': intended,
      }, baseRevision: (s.settings['revision'] as num?)?.toInt() ?? 1);
    } catch (error) {
      if (mounted && identity == _identityKey) {
        notifyOffice(context, friendlyError(error));
      }
    } finally {
      if (mounted && _collapsePendingIdentity == identity) {
        setState(() => _collapsePendingIdentity = null);
      }
    }
  }

  Widget _rail() {
    final collapsed = _desktopCollapsed;
    final avatar = _profileButton(
      PersonAvatar(
        name: str(s.me?['name']),
        agent: s.me?['kind'] == 'agent',
        size: 34,
      ),
    );
    final toggle = IconButton(
      key: const ValueKey('desktop-navigation-collapse'),
      tooltip: collapsed ? '展开导航栏' : '收起导航栏',
      onPressed: s.connected && _collapsePendingIdentity != _identityKey
          ? _toggleDesktopNavigation
          : null,
      icon: Icon(
        collapsed
            ? Icons.keyboard_double_arrow_right
            : Icons.keyboard_double_arrow_left,
        size: 19,
      ),
    );
    final editor = IconButton(
      key: const ValueKey('desktop-navigation-editor'),
      tooltip: '编辑导航栏',
      onPressed: () => showOfficeDesktopNavigationEditor(context, s),
      icon: const Icon(Icons.more_horiz, size: 20),
    );
    return SizedBox(
      key: const ValueKey('desktop-navigation-rail'),
      width: collapsed ? 72 : 180,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          collapsed ? 8 : 15,
          21,
          collapsed ? 8 : 14,
          15,
        ),
        child: Column(
          children: [
            if (collapsed) ...[
              avatar,
              _quickMenu(),
            ] else
              Row(
                children: [
                  avatar,
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '人机',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          str(s.me?['name']),
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
                  _quickMenu(),
                ],
              ),
            SizedBox(height: collapsed ? 4 : 23),
            if (collapsed)
              IconButton(
                tooltip: '搜索',
                onPressed: () => _search(''),
                icon: const Icon(Icons.search, size: 21),
              )
            else
              OfficeSearch(hint: '搜索', onChanged: _search),
            SizedBox(height: collapsed ? 8 : 22),
            Expanded(
              child: ListView(
                children: _desktopNavigation.map((entry) {
                  final selected = _nav == entry.route;
                  final unread =
                      entry.route == 0 &&
                      s.rooms.any((room) => officeNotificationCount(room) > 0);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: selected
                          ? const Color(0xffdde6fc)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      child: Builder(
                        builder: (itemContext) => CallbackShortcuts(
                          bindings: {
                            const SingleActivator(
                              LogicalKeyboardKey.f10,
                              shift: true,
                            ): () =>
                                _desktopMenu(itemContext, entry),
                            const SingleActivator(
                              LogicalKeyboardKey.contextMenu,
                            ): () =>
                                _desktopMenu(itemContext, entry),
                          },
                          child: Tooltip(
                            message: entry.label,
                            child: InkWell(
                              key: ValueKey('desktop-nav-${entry.id}'),
                              onSecondaryTapDown: (details) => _desktopMenu(
                                itemContext,
                                entry,
                                details.globalPosition,
                              ),
                              onLongPress: () =>
                                  _desktopMenu(itemContext, entry),
                              onTap: () => _changeNav(entry.route),
                              borderRadius: BorderRadius.circular(6),
                              child: Stack(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 11,
                                    ),
                                    child: Row(
                                      mainAxisAlignment: collapsed
                                          ? MainAxisAlignment.center
                                          : MainAxisAlignment.start,
                                      children: [
                                        Icon(
                                          entry.icon,
                                          size: 19,
                                          color: selected
                                              ? accentColor
                                              : const Color(0xff626f87),
                                        ),
                                        if (!collapsed) ...[
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              entry.label,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: selected
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                                color: selected
                                                    ? accentColor
                                                    : const Color(0xff43516b),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (unread)
                                    Positioned(
                                      right: 7,
                                      top: collapsed ? 7 : 17,
                                      child: Container(
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: Color(0xfff56c6c),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            if (collapsed) ...[
              editor,
              toggle,
            ] else
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [toggle, editor],
              ),
            if (_media.activeMeeting != null && _nav != 6)
              if (collapsed)
                IconButton(
                  tooltip: '返回当前会议',
                  onPressed: () => _changeNav(6),
                  icon: const Icon(Icons.videocam),
                )
              else
                _callStrip(),
            Row(
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Tooltip(
                  message: s.connected ? '消息已同步' : '正在重新连接',
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: s.connected
                          ? const Color(0xff62b98c)
                          : const Color(0xffe5b775),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 7),
                  Text(
                    s.connected ? '消息已同步' : '正在重新连接',
                    style: const TextStyle(
                      fontSize: 9,
                      color: Color(0xff98a3b7),
                    ),
                  ),
                  const Spacer(),
                ],
                IconButton(
                  onPressed: () async {
                    final identity = _identityKey;
                    try {
                      await s.refresh();
                    } catch (error) {
                      if (mounted && identity == _identityKey) {
                        notifyOffice(context, friendlyError(error));
                      }
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
            if (!collapsed) ...[
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
          ],
        ),
      ),
    );
  }

  Widget _mobile() {
    if (_nav == 11) return Material(color: Colors.white, child: _main(true));
    if (!_navAvailable) {
      return Material(color: Colors.white, child: _main(true));
    }
    if (_nav == 0 && _roomOpen) {
      return Material(
        color: Colors.white,
        child: OfficeConversation(
          onAgentStore: () {
            _agentStore = true;
            _changeNav(1);
          },
          state: s,
          mobile: true,
          onCreateCalendar: () {
            _changeNav(7);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _calendarKey.currentState?.createEvent(),
            );
          },
          onCreateMeeting: () {
            _changeNav(6);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _meetingsKey.currentState?.createMeeting(),
            );
          },
          onBack: () => setState(() => _roomOpen = false),
        ),
      );
    }
    if (_searchOpen) {
      return Material(color: Colors.white, child: _searchResults());
    }
    return Material(
      color: Colors.white,
      child: _nav == 0
          ? _roomList(mobile: true)
          : Column(
              children: [
                if (!(_nav == 6 && _media.activeMeeting != null))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                    child: Row(
                      children: [
                        _profileButton(
                          PersonAvatar(
                            name: str(s.me?['name']),
                            agent: s.me?['kind'] == 'agent',
                            size: 27,
                          ),
                        ),
                        const SizedBox(width: 9),
                        const Expanded(
                          child: Text(
                            '人机工作空间',
                            style: TextStyle(fontSize: 11, color: mutedColor),
                          ),
                        ),
                        IconButton(
                          tooltip: '全局搜索',
                          onPressed: () => setState(() => _searchOpen = true),
                          icon: const Icon(Icons.search, size: 21),
                        ),
                        _quickMenu(),
                      ],
                    ),
                  ),
                Expanded(child: _main(true)),
              ],
            ),
    );
  }

  String? _moduleFor(int nav) => const {
    0: 'im',
    1: 'im',
    2: 'im',
    3: 'docs',
    4: 'tasks',
    5: 'workbench',
    6: 'meetings',
    7: 'calendar',
    8: 'mail',
    9: 'attendance',
    10: 'approvals',
    14: 'minutes',
  }[nav];
  bool get _navAvailable =>
      _moduleFor(_nav) == null || s.moduleAvailable(_moduleFor(_nav)!);
  Widget _main(bool mobile) => _modulePage(_nav, mobile);

  Widget _modulePage(
    int route,
    bool mobile, {
    VoidCallback? onBack,
    ValueChanged<int>? navigate,
  }) {
    final go = navigate ?? _changeNav;
    final module = _moduleFor(route);
    if (module != null && !s.moduleAvailable(module)) {
      return EmptyOffice(
        title: '企业策略已限制此应用',
        subtitle: '当前身份不在可用范围，或关联能力受到限制。可以在企业管理中查看权限。',
        icon: Icons.lock_outline,
        action: Wrap(
          spacing: 10,
          children: [
            TextButton(onPressed: () => go(11), child: const Text('打开设置')),
            TextButton(onPressed: () => go(13), child: const Text('企业管理')),
          ],
        ),
      );
    }
    switch (route) {
      case 0:
        if (navigate == null && _foldedOpen && !_roomOpen) {
          return const EmptyOffice(
            title: '折叠的会话',
            subtitle: '选择一个会话，继续共同协作。',
            icon: Icons.unfold_less,
          );
        }
        return OfficeConversation(
          state: s,
          onCreateCalendar: () {
            final identity = _identityKey;
            go(7);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  identity == _identityKey &&
                  s.moduleAvailable('calendar')) {
                _calendarKey.currentState?.createEvent();
              }
            });
          },
          onCreateMeeting: () {
            final identity = _identityKey;
            go(6);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  identity == _identityKey &&
                  s.moduleAvailable('meetings')) {
                _meetingsKey.currentState?.createMeeting();
              }
            });
          },
          onAgentStore: () {
            _agentStore = true;
            go(1);
          },
        );
      case 1:
        return OfficePeople(
          key: ValueKey('agents-$_agentStore'),
          initialStore: _agentStore,
          state: s,
          agent: true,
          onConversation: () {
            if (navigate != null) {
              go(0);
            } else {
              setState(() {
                _nav = 0;
                _roomOpen = true;
              });
            }
          },
        );
      case 2:
        return OfficePeople(
          key: const ValueKey('humans'),
          state: s,
          agent: false,
          onConversation: () {
            if (navigate != null) {
              go(0);
            } else {
              setState(() {
                _nav = 0;
                _roomOpen = true;
              });
            }
          },
        );
      case 3:
        return WorkDocuments(state: s);
      case 4:
        return WorkTaskLibrary(state: s);
      case 6:
        return OfficeMeetings(
          key: _meetingsKey,
          state: s,
          media: _media,
          onCalendar: () => go(7),
        );
      case 7:
        return OfficeCalendar(
          key: _calendarKey,
          state: s,
          onMeeting: (id) async {
            if (navigate == null) {
              await _joinMeeting(id);
            } else {
              go(6);
              await _media.join(s, id);
            }
          },
        );
      case 8:
        return OfficeMailbox(key: _mailKey, state: s);
      case 9:
        return OfficeAttendance(state: s);
      case 10:
        return OfficeApprovals(key: _approvalsKey, state: s);
      case 11:
        return OfficeSettings(
          key: ValueKey('settings-$_settingsTab'),
          state: s,
          initialTab: _settingsTab,
          onClose: onBack ?? _closeSettings,
          onMessageGroups: () =>
              showOfficeMessageGroupEditor(context, _messageGroups),
          onNavigation: () => showOfficeNavigationEditor(context, s),
          onOpenModule: go,
          onEnterprise: s.canManageEnterprise ? () => go(13) : null,
        );
      case 12:
        return _more();
      case 13:
        return OfficeEnterprise(state: s);
      case 14:
        return OfficeMinutes(key: _minutesKey, state: s);
      default:
        return OfficeWorkbenchNavigator(
          key: ValueKey('workbench-$_identityKey'),
          state: s,
          pageBuilder: (appRoute, back, open) =>
              _modulePage(appRoute, mobile, onBack: back, navigate: open),
        );
    }
  }

  Widget _more() => ListView(
    padding: const EdgeInsets.all(22),
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.view_carousel_outlined, color: accentColor),
        title: const Text('编辑底栏', style: TextStyle(fontSize: 14)),
        trailing: const Icon(Icons.tune, size: 18),
        onTap: () => showOfficeNavigationEditor(context, s),
      ),
      ...officeNavigationItems
          .where(
            (item) =>
                item.id != 'enterprise' &&
                !officeMobileNavigation(s)
                    .any((pinned) => pinned.id == item.id),
          )
          .map(
            (item) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(item.icon, color: accentColor),
              title: Text(item.label, style: const TextStyle(fontSize: 14)),
              trailing: const Icon(
                Icons.chevron_right,
                size: 19,
                color: mutedColor,
              ),
              onTap: () => _changeNav(item.route),
            ),
          ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.settings_outlined, color: accentColor),
        title: const Text('设置', style: TextStyle(fontSize: 14)),
        trailing: const Icon(Icons.chevron_right, size: 19, color: mutedColor),
        onTap: () {
          _settingsTab = -1;
          _changeNav(11);
        },
      ),
      if (s.canManageEnterprise)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.apartment_outlined, color: accentColor),
          title: const Text('企业管理', style: TextStyle(fontSize: 14)),
          trailing: const Icon(
            Icons.chevron_right,
            size: 19,
            color: mutedColor,
          ),
          onTap: () => _changeNav(13),
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
    final folded = s.rooms.where(officeRoomFolded).toList();
    if (_foldedOpen) {
      return OfficeFoldedConversations(
        key: ValueKey('folded-$_identityKey'),
        rooms: folded,
        onBack: () => setState(() => _foldedOpen = false),
        itemBuilder: (room) => _conversationRow(room, mobile),
      );
    }
    final favorites = s.rooms
        .where(
          (r) =>
              !officeRoomFolded(r) &&
              (r['is_favorite'] == true ||
                  (r['preferences'] as Map?)?['favorite'] == true),
        )
        .toList();
    final rooms = _messageGroups.filteredRooms
        .where(
          (r) =>
              str(r['name']).toLowerCase().contains(_roomQuery.toLowerCase()) &&
              (!_unreadOnly || officeUnreadCount(r) > 0) &&
              (_messageGroups.selectedId != 'messages' ||
                  _roomQuery.trim().isNotEmpty ||
                  !officeRoomFolded(r)),
        )
        .toList();
    final showFoldedSummary =
        folded.isNotEmpty &&
        _messageGroups.selectedId == 'messages' &&
        _roomQuery.trim().isEmpty;
    final originalOrder = {
      for (var i = 0; i < rooms.length; i++) str(rooms[i]['id']): i,
    };
    rooms.sort((a, b) {
      final pinned =
          (b['is_pinned'] == true ? 1 : 0) - (a['is_pinned'] == true ? 1 : 0);
      return pinned != 0
          ? pinned
          : originalOrder[str(a['id'])]!.compareTo(
              originalOrder[str(b['id'])]!,
            );
    });
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(19, mobile ? 20 : 22, 12, 15),
          child: Row(
            children: [
              if (mobile) ...[
                _profileButton(
                  PersonAvatar(
                    name: str(s.me?['name']),
                    agent: s.me?['kind'] == 'agent',
                    size: 36,
                  ),
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
                            '人机工作空间',
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
                IconButton(
                  tooltip: '全局搜索',
                  onPressed: () => setState(() => _searchOpen = true),
                  icon: const Icon(Icons.search, size: 22),
                )
              else
                IconButton(
                  onPressed: () => _toggleGroups(false),
                  tooltip: '消息分组',
                  icon: Icon(
                    Icons.menu,
                    color: _groupsOpen ? accentColor : mutedColor,
                    size: 20,
                  ),
                ),
              _quickMenu(),
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
        if (favorites.isNotEmpty && _messageGroups.selectedId == 'messages')
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
              if (mobile)
                IconButton(
                  tooltip: '消息分组',
                  onPressed: () => _toggleGroups(true),
                  icon: const Icon(Icons.menu, size: 20),
                ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final id
                          in _messageGroups.loaded
                              ? _messageGroups.shortcuts
                              : ['messages', 'unread'])
                        Padding(
                          padding: const EdgeInsets.only(right: 7),
                          child: ChoiceChip(
                            label: Text(
                              str(
                                _messageGroups.group(id)?['name'],
                                id == 'unread' ? '未读' : '消息',
                              ),
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: _messageGroups.selectedId == id,
                            showCheckmark: false,
                            side: BorderSide.none,
                            onSelected: (_) => _selectMessageGroup(id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_messageGroups.selectedId == 'marked')
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('open-marked-messages'),
              onPressed: _openMarkedMessages,
              icon: const Icon(Icons.bookmark_outline, size: 18),
              label: const Text('查看已标记消息'),
            ),
          ),
        if (_messageGroups.group(_messageGroups.selectedId)?['type'] == 'label')
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 10, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    str(
                      _messageGroups.group(_messageGroups.selectedId)?['name'],
                    ),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '标签操作',
                  icon: const Icon(Icons.more_horiz, size: 20),
                  onSelected: (action) {
                    final label = _messageGroups.group(
                      _messageGroups.selectedId,
                    )!;
                    if (action == 'add') {
                      showOfficeMessageLabelRooms(
                        context,
                        _messageGroups,
                        label,
                      );
                    }
                    if (action == 'edit') {
                      showOfficeMessageLabelEditor(
                        context,
                        _messageGroups,
                        label: label,
                      );
                    }
                    if (action == 'delete') {
                      deleteOfficeMessageLabel(context, _messageGroups, label);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'add', child: Text('添加会话')),
                    PopupMenuItem(value: 'edit', child: Text('编辑标签与规则')),
                    PopupMenuItem(value: 'delete', child: Text('删除标签')),
                  ],
                ),
              ],
            ),
          ),
        Expanded(
          child: rooms.isEmpty && !showFoldedSummary
              ? Padding(
                  padding: const EdgeInsets.all(23),
                  child: Center(
                    child: Text(
                      _unreadOnly
                          ? '没有未读消息'
                          : _messageGroups.selectedId != 'messages'
                          ? '此分组暂无会话'
                          : '还没有工作会话\n创建工作群，或从通讯录发起私聊。',
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
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  itemCount: rooms.length + (showFoldedSummary ? 1 : 0),
                  itemBuilder: (context, index) {
                    final folderIndex = rooms
                        .takeWhile((room) => room['is_pinned'] == true)
                        .length;
                    if (showFoldedSummary && index == folderIndex) {
                      return OfficeFoldedSummary(
                        key: const ValueKey('folded-summary'),
                        rooms: folded,
                        onOpen: () => setState(() {
                          _foldedOpen = true;
                          _roomOpen = false;
                        }),
                      );
                    }
                    final roomIndex = showFoldedSummary && index > folderIndex
                        ? index - 1
                        : index;
                    return _conversationRow(rooms[roomIndex], mobile);
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
  Widget _searchResults() {
    final results = s.searchResults;
    const domains = {
      'all': '全部',
      'person': '联系人',
      'agent': 'Agent 好友',
      'store': 'Agent 商店',
      'message': '消息',
      'document': '文档',
      'task': '任务',
      'mail': '邮件',
      'approval': '审批',
      'calendar': '日程',
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                        _moveSearchResult(1),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                        _moveSearchResult(-1),
                    const SingleActivator(LogicalKeyboardKey.enter): () {
                      final composing = _globalSearchInput.value.composing;
                      if (!composing.isValid || composing.isCollapsed) {
                        _activateSearchResult();
                      }
                    },
                  },
                  child: TextField(
                    controller: _globalSearchInput,
                    focusNode: _globalSearchFocus,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索人、Agent 和工作内容',
                      prefixIcon: Icon(Icons.search, size: 19),
                    ),
                    onChanged: _search,
                  ),
                ),
              ),
              IconButton(
                onPressed: _closeSearch,
                tooltip: '关闭搜索',
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 45,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: domains.entries
                .map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        e.value,
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: _searchType == e.key,
                      showCheckmark: false,
                      onSelected: (_) {
                        _searchType = e.key;
                        _searchFilters = _searchFilters.forType(e.key);
                        _search(_globalQuery);
                      },
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              if (!['person', 'agent', 'store'].contains(_searchType))
                OutlinedButton.icon(
                  onPressed: _filterSearch,
                  icon: const Icon(Icons.tune, size: 16),
                  label: Text(_searchFilters.active ? '筛选已启用' : '作者 / 会话 / 日期'),
                ),
              if (_searchFilters.active)
                IconButton(
                  tooltip: '清除搜索筛选',
                  onPressed: () {
                    _searchFilters = const OfficeSearchFilters();
                    _search(_globalQuery);
                  },
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                ),
              const Spacer(),
              if (MediaQuery.sizeOf(context).width >= 900)
                const Text(
                  '⌘ / Ctrl K 搜索 · ↑↓ 选择 · Enter 打开 · Esc 返回',
                  style: TextStyle(fontSize: 10, color: mutedColor),
                ),
            ],
          ),
        ),
        if (!_searching && _globalQuery.trim().isNotEmpty && s.searchTruncated)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '结果较多，当前只展示部分匹配项。请增加关键词或筛选条件。',
              style: TextStyle(fontSize: 11, color: mutedColor),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _globalQuery.trim().isEmpty
              ? const EmptyOffice(
                  title: '搜索整个工作空间',
                  subtitle: '找到工作伙伴、商店 Agent 与有权访问的工作内容。',
                  icon: Icons.search,
                )
              : _searching
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _searchError != null
              ? EmptyOffice(
                  title: '搜索暂时无法完成',
                  subtitle: _searchError!,
                  icon: Icons.search_off_outlined,
                )
              : results.isEmpty
              ? const EmptyOffice(
                  title: '没有找到匹配内容',
                  subtitle: '试试其他关键词或切换分类。',
                  icon: Icons.search,
                )
              : ListView.builder(
                  controller: _searchScroll,
                  padding: const EdgeInsets.all(20),
                  itemExtent: 104,
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final result = results[index],
                        type = str(results[index]['type']);
                    return Material(
                      color: index == _selectedSearchResult
                          ? selectedColor
                          : Colors.white,
                      child: ListTile(
                        key: ValueKey('search-result-$index'),
                        selected: index == _selectedSearchResult,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          const {
                                'person': Icons.person_outline,
                                'agent': Icons.auto_awesome_outlined,
                                'store': Icons.storefront_outlined,
                                'document': Icons.description_outlined,
                                'task': Icons.task_alt,
                                'mail': Icons.mail_outline,
                                'approval': Icons.fact_check_outlined,
                                'calendar': Icons.calendar_month_outlined,
                              }[type] ??
                              Icons.chat_bubble_outline,
                          color: accentColor,
                          size: 22,
                        ),
                        title: Text(
                          str(result['title'], '工作内容'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${domains[type] ?? '工作内容'}${result['at'] == null ? '' : ' · ${clockText(result['at'], date: true, context: context)}'}\n${str(result['snippet'], str(result['content']))}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: mutedColor,
                            height: 1.8,
                          ),
                        ),
                        onTap: () => _openSearchResult(result),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openSearchResult(Json result) async {
    try {
      final type = str(result['type']);
      if (type == 'person' || type == 'agent') {
        await s.openDirect(str(result['id']));
        if (mounted) {
          setState(() {
            _nav = 0;
            _roomOpen = true;
            _searchOpen = false;
            _globalQuery = '';
          });
        }
        return;
      }
      if (type == 'store') {
        _agentStore = true;
        _changeNav(1);
        return;
      }
      if (type == 'mail') {
        _changeNav(8);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _mailKey.currentState?.open(str(result['id'])),
        );
        return;
      }
      if (type == 'approval') {
        _changeNav(10);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _approvalsKey.currentState?.open(str(result['id'])),
        );
        return;
      }
      if (type == 'calendar') {
        _changeNav(7);
        if (result['event'] is Map) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _calendarKey.currentState?.openEvent(
              Json.from(result['event']),
            ),
          );
        }
        return;
      }
      if (type == 'document') {
        await OfficeDialogs.document(context, s, {
          'id': result['id'],
          'room_id': result['room_id'],
        });
        return;
      }
      if (type == 'task') {
        final task = s.allTasks
            .where((t) => t['id'] == result['id'])
            .firstOrNull;
        if (task == null) {
          notifyOffice(context, '任务列表已变化，请刷新后重新打开。');
          return;
        }
        await WorkTaskLibrary.openTask(context, s, task);
        return;
      }
      await _open(str(result['room_id']));
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  String? _quickModule(String action) => const {
    'group': 'im',
    'person': 'im',
    'agent': 'im',
    'store': 'im',
    'document': 'docs',
    'task': 'tasks',
    'meeting': 'meetings',
    'join': 'meetings',
    'calendar': 'calendar',
    'approval': 'approvals',
    'mail': 'mail',
    'minutes': 'minutes',
  }[action];
  Widget _quickMenu() => PopupMenuButton<String>(
    tooltip: '新建与添加',
    padding: EdgeInsets.zero,
    icon: const Icon(Icons.add_circle_outline, size: 21),
    onSelected: _quickAction,
    itemBuilder: (_) =>
        const {
              'group': '创建群组 · 人与 Agent',
              'person': '添加联系人 / 发起私聊',
              'agent': '添加 Agent 好友',
              'store': '安装商店 Agent',
              'document': '创建文档',
              'task': '分派任务',
              'meeting': '发起视频会议',
              'join': '加入视频会议',
              'calendar': '新建日程',
              'approval': '发起审批',
              'mail': '写邮件',
              'minutes': '人机妙记',
            }.entries
            .map(
              (entry) => PopupMenuItem<String>(
                value: entry.key,
                enabled: s.moduleAvailable(_quickModule(entry.key)!),
                child: Text(entry.value),
              ),
            )
            .toList(),
  );

  Future<void> _quickAction(String action) async {
    final module = _quickModule(action);
    if (module != null && !s.moduleAvailable(module)) {
      notifyOffice(context, '企业策略已限制此应用');
      return;
    }
    try {
      if (action == 'group') {
        await OfficeDialogs.createRoom(context, s);
        return;
      }
      if (action == 'agent' || action == 'store') {
        _agentStore = action == 'store';
        _changeNav(1);
        return;
      }
      if (action == 'person') {
        final ids = await chooseOfficePeople(
          context,
          s,
          single: true,
          title: '选择联系人',
          people: s.principals
              .where(
                (p) =>
                    p['kind'] != 'agent' && personId(p) != personId(s.me ?? {}),
              )
              .toList(),
        );
        if (ids?.isNotEmpty == true) {
          await s.addContact(ids!.single);
          await s.openDirect(ids.single);
          if (mounted) {
            setState(() {
              _nav = 0;
              _roomOpen = true;
            });
          }
        }
        return;
      }
      if (action == 'document') {
        await OfficeDialogs.document(context, s);
        return;
      }
      if (action == 'task') {
        await OfficeDialogs.task(context, s);
        return;
      }
      final nav = {
        'meeting': 6,
        'join': 6,
        'calendar': 7,
        'approval': 10,
        'mail': 8,
        'minutes': 14,
      }[action];
      if (nav == null) return;
      _changeNav(nav);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (action == 'meeting') _meetingsKey.currentState?.createMeeting();
        if (action == 'join') _meetingsKey.currentState?.joinMeeting();
        if (action == 'calendar') _calendarKey.currentState?.createEvent();
        if (action == 'approval') _approvalsKey.currentState?.create();
        if (action == 'mail') _mailKey.currentState?.compose();
        if (action == 'minutes') _minutesKey.currentState?.createMinute();
      });
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }
}
