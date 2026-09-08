import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../message_groups.dart';
import '../office_state.dart' hide Json;
import 'conversation_list.dart';
import 'message_group_labels.dart';
import 'office_dialogs.dart' show friendlyError;
import 'office_theme.dart';

enum OfficeConversationAction {
  pin,
  clearUnread,
  mark,
  labels,
  mute,
  complete,
  agent,
}

class _ConversationMenuEntry {
  const _ConversationMenuEntry(
    this.action,
    this.label,
    this.icon, {
    this.enabled = true,
  });
  final OfficeConversationAction action;
  final String label;
  final IconData icon;
  final bool enabled;
}

/// Personal room actions always target the row that opened the menu. Merely
/// opening it never selects a room, acknowledges unread messages or sends text.
Future<void> showOfficeConversationContextMenu(
  BuildContext context,
  OfficeState state,
  OfficeMessageGroups groups,
  Json room, {
  required Rect anchor,
  required Future<void> Function() onAgent,
}) async {
  final roomId = str(room['id']);
  final generation = state.identityGeneration;
  final endpoint = state.endpoint;
  final principal = personId(state.me ?? {});
  bool current() =>
      context.mounted &&
      state.connected &&
      state.me != null &&
      state.identityGeneration == generation &&
      state.endpoint == endpoint &&
      personId(state.me ?? {}) == principal &&
      state.rooms.any((item) => item['id'] == roomId);
  if (!current()) return;
  final grouping = room['message_grouping'] as Map?;
  final marked = grouping?['marked'] == true;
  final completed = grouping?['completed'] == true;
  final groupAvailable = grouping != null && groups.loaded;
  final revision = groups.revision;
  final pinned = officeRoomPinned(room), muted = officeRoomMuted(room);
  final readSequence =
      ((room['last_message'] as Map?)?['seq'] as num?)?.toInt() ?? 0;
  final entries = [
    _ConversationMenuEntry(
      OfficeConversationAction.pin,
      pinned ? '取消置顶' : '置顶',
      Icons.vertical_align_top,
    ),
    _ConversationMenuEntry(
      OfficeConversationAction.clearUnread,
      '清除未读',
      Icons.cleaning_services_outlined,
      enabled: officeUnreadCount(room) > 0 && readSequence > 0,
    ),
    _ConversationMenuEntry(
      OfficeConversationAction.mark,
      marked ? '取消标记' : '标记',
      Icons.outlined_flag,
      enabled: groupAvailable,
    ),
    _ConversationMenuEntry(
      OfficeConversationAction.labels,
      '标签',
      Icons.label_outline,
      enabled: groups.loaded,
    ),
    _ConversationMenuEntry(
      OfficeConversationAction.mute,
      muted ? '允许消息通知' : '关闭消息通知',
      Icons.notifications_none,
    ),
    _ConversationMenuEntry(
      OfficeConversationAction.complete,
      completed ? '撤销完成' : '完成',
      Icons.check,
      enabled: groupAvailable,
    ),
    const _ConversationMenuEntry(
      OfficeConversationAction.agent,
      'Agent 超级入口',
      Icons.auto_awesome_outlined,
    ),
  ];
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = _ConversationMenuRoute(anchor: anchor, entries: entries);
  void scopeChanged() {
    if (!current() && route.isActive) navigator.removeRoute(route);
  }

  state.addListener(scopeChanged);
  OfficeConversationAction? action;
  try {
    action = await navigator.push(route);
  } finally {
    state.removeListener(scopeChanged);
  }
  if (action == null || !context.mounted || !current()) return;
  try {
    if (action == OfficeConversationAction.labels) {
      await showOfficeRoomGrouping(context, groups, room);
      return;
    }
    if (action == OfficeConversationAction.agent) {
      await onAgent();
      return;
    }
    final preferences = switch (action) {
      OfficeConversationAction.pin => <String, dynamic>{'pinned': !pinned},
      OfficeConversationAction.clearUnread => <String, dynamic>{
        'read_seq': readSequence,
      },
      OfficeConversationAction.mute => <String, dynamic>{'muted': !muted},
      _ => null,
    };
    if (preferences != null) {
      await state.officeRequest(
        '/rooms/${Uri.encodeComponent(roomId)}/preferences',
        method: 'PATCH',
        data: preferences,
      );
    } else {
      await groups.updateRoom(roomId, {
        if (action == OfficeConversationAction.mark) 'marked': !marked,
        if (action == OfficeConversationAction.complete)
          'completed': !completed,
      }, baseRevision: revision);
    }
    if (current()) await state.refresh();
  } catch (error) {
    if (context.mounted && current()) {
      notifyOffice(context, friendlyError(error));
    }
  }
}

class _ConversationMenuRoute extends PopupRoute<OfficeConversationAction> {
  _ConversationMenuRoute({required this.anchor, required this.entries});
  final Rect anchor;
  final List<_ConversationMenuEntry> entries;
  @override
  Color get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  String get barrierLabel => '关闭会话菜单';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final mobile = media.size.width < 760;
    final fontSize = mobile ? 17.0 : 14.0;
    final width = math.min(mobile ? 256.0 : 220.0, media.size.width - 32);
    final availableHeight = math.max(
      0.0,
      media.size.height - media.padding.vertical - media.viewInsets.bottom - 16,
    );
    final rowHeight = math.max(
      mobile ? 46.0 : 36.0,
      media.textScaler.scale(fontSize) * 1.3 + 20,
    );
    final height = math.min(
      availableHeight,
      entries.length * rowHeight + entries.length - 1,
    );
    final top = anchor.center.dy.clamp(
      media.padding.top + 8,
      math.max(
        media.padding.top + 8,
        media.size.height -
            media.padding.bottom -
            media.viewInsets.bottom -
            height -
            8,
      ),
    );
    return Stack(
      children: [
        Positioned(
          left: (anchor.right - width).clamp(16, media.size.width - width - 16),
          top: top.toDouble(),
          width: width,
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            namesRoute: true,
            label: '会话操作',
            child: Material(
              key: const ValueKey('conversation-context-menu'),
              color: const Color(0xfffbfbfc),
              surfaceTintColor: Colors.transparent,
              elevation: 12,
              shadowColor: Colors.black26,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: availableHeight),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var index = 0; index < entries.length; index++) ...[
                        if (index > 0) const Divider(height: 1, thickness: .5),
                        _menuItem(context, entries[index], rowHeight, fontSize),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuItem(
    BuildContext context,
    _ConversationMenuEntry entry,
    double height,
    double fontSize,
  ) => InkWell(
    key: ValueKey('conversation-menu-${entry.action.name}'),
    onTap: entry.enabled
        ? () {
            if (isCurrent) navigator?.pop(entry.action);
          }
        : null,
    child: SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                entry.label,
                style: TextStyle(
                  fontSize: fontSize,
                  height: 1.3,
                  color: entry.enabled ? inkColor : mutedColor,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              entry.icon,
              size: 23,
              color: entry.enabled ? inkColor : mutedColor,
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  );
}
