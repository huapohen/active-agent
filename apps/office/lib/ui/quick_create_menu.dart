import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'office_theme.dart';

class OfficeQuickCreateAction {
  const OfficeQuickCreateAction(
    this.id,
    this.label,
    this.icon, {
    this.module,
    this.unavailableMessage,
  });

  final String id, label;
  final IconData icon;
  final String? module, unavailableMessage;
}

/// IDs for working entries match OfficeShell's existing native actions.
/// Unsupported reference entries explain their status and never dispatch work.
const officeQuickCreateActions = <OfficeQuickCreateAction>[
  OfficeQuickCreateAction(
    'scan',
    '扫一扫',
    CupertinoIcons.viewfinder,
    unavailableMessage: '扫一扫尚未接入，当前不能识别二维码或添加扫码结果。',
  ),
  OfficeQuickCreateAction(
    'group',
    '创建群组',
    CupertinoIcons.person_2,
    module: 'im',
  ),
  OfficeQuickCreateAction(
    'person',
    '添加联系人',
    CupertinoIcons.person_badge_plus,
    module: 'im',
  ),
  OfficeQuickCreateAction(
    'agent',
    '添加 Agent 好友',
    Icons.smart_toy_outlined,
    module: 'im',
  ),
  OfficeQuickCreateAction(
    'store',
    '安装商店 Agent',
    Icons.storefront_outlined,
    module: 'im',
  ),
  OfficeQuickCreateAction(
    'minutes',
    '人机妙记',
    CupertinoIcons.mic,
    module: 'minutes',
  ),
  OfficeQuickCreateAction(
    'document',
    '创建文档',
    CupertinoIcons.doc_text,
    module: 'docs',
  ),
  OfficeQuickCreateAction(
    'multitable',
    '创建多维表格',
    CupertinoIcons.square_grid_2x2,
    unavailableMessage: '多维表格尚未接入，可先通过“创建文档”协作记录内容。',
  ),
  OfficeQuickCreateAction(
    'questionnaire',
    '创建问卷',
    CupertinoIcons.checkmark_square,
    unavailableMessage: '问卷尚未接入，当前不能创建或收集问卷结果。',
  ),
  OfficeQuickCreateAction(
    'cast',
    '会议室投屏',
    CupertinoIcons.tv,
    unavailableMessage: '会议室设备投屏尚未接入。会议内的屏幕共享需先加入视频会议。',
  ),
  OfficeQuickCreateAction(
    'meeting',
    '发起视频会议',
    CupertinoIcons.video_camera,
    module: 'meetings',
  ),
  OfficeQuickCreateAction(
    'join',
    '加入视频会议',
    CupertinoIcons.plus_app,
    module: 'meetings',
  ),
  OfficeQuickCreateAction(
    'task',
    '分派任务',
    Icons.assignment_outlined,
    module: 'tasks',
  ),
  OfficeQuickCreateAction(
    'calendar',
    '新建日程',
    CupertinoIcons.calendar,
    module: 'calendar',
  ),
  OfficeQuickCreateAction(
    'approval',
    '发起审批',
    CupertinoIcons.checkmark_seal,
    module: 'approvals',
  ),
  OfficeQuickCreateAction(
    'mail',
    '写邮件',
    CupertinoIcons.envelope,
    module: 'mail',
  ),
];

/// Mobile opens below +, aligned to its right edge. Desktop opens beside +,
/// preferring the right side and flipping left only when space is insufficient.
/// Both constrain the scroll height so a long list cannot displace its anchor.
class OfficeQuickCreateMenu extends StatefulWidget {
  const OfficeQuickCreateMenu({
    super.key,
    required this.onSelected,
    this.isModuleAvailable,
    this.scopeKey,
    this.enabled = true,
    this.menuWidth = 240,
    this.mobileMenuWidth = 180,
    this.actions = officeQuickCreateActions,
  });

  final FutureOr<void> Function(String action) onSelected;
  final bool Function(String module)? isModuleAvailable;
  final Object? scopeKey;
  final bool enabled;
  final double menuWidth;
  final double mobileMenuWidth;
  final List<OfficeQuickCreateAction> actions;

  @override
  State<OfficeQuickCreateMenu> createState() => _OfficeQuickCreateMenuState();
}

class _OfficeQuickCreateMenuState extends State<OfficeQuickCreateMenu> {
  final _anchor = GlobalKey();
  bool _opening = false;

  bool _permitted(OfficeQuickCreateAction action) =>
      action.module == null ||
      widget.isModuleAvailable?.call(action.module!) != false;

  void _explain(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _show() async {
    if (_opening || !widget.enabled || widget.actions.isEmpty) return;
    final mobile = MediaQuery.sizeOf(context).width < 760;
    final actions = widget.actions
        .where((action) => mobile || action.id != 'scan')
        .toList();
    if (actions.isEmpty) return;
    final button = _anchor.currentContext?.findRenderObject();
    final overlayContext = Navigator.of(context).overlay?.context;
    final overlay = overlayContext?.findRenderObject();
    if (button is! RenderBox || overlay is! RenderBox) return;
    final scope = widget.scopeKey;
    final rect =
        button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
    // The trigger lives inside SafeArea, where padding has already been
    // consumed. The popup route uses the overlay's full safe insets instead.
    final safe = MediaQuery.paddingOf(overlayContext!);
    final width = math.min(
      mobile ? widget.mobileMenuWidth : widget.menuWidth,
      math.max(1.0, overlay.size.width - safe.horizontal - 16),
    );
    final rightEdge = overlay.size.width - safe.right - 8;
    final preferredLeft = mobile
        ? rect.right - width
        : rect.right + 8 + width <= rightEdge
        ? rect.right + 8
        : rect.left - width - 8;
    final left = preferredLeft
        .clamp(
          safe.left + 8,
          math.max(safe.left + 8, overlay.size.width - width - safe.right - 8),
        )
        .toDouble();
    final top = mobile ? rect.bottom + 8 : math.max(safe.top + 8, rect.top);
    final maxHeight = math.max(
      1.0,
      // showMenu also reserves an 8px screen margin outside safe padding.
      // Reserving both here prevents its fit-to-screen pass moving the top.
      overlay.size.height - safe.bottom - 8 - top,
    );
    _opening = true;
    String? selected;
    try {
      selected = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(left, top, width, 0),
          Offset.zero & overlay.size,
        ),
        constraints: BoxConstraints(
          minWidth: width,
          maxWidth: width,
          maxHeight: maxHeight,
        ),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shadowColor: const Color(0x26000000),
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        semanticLabel: '新建与添加',
        popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(
                // Feishu's add menu feels synchronous with the trigger. Keep
                // a tiny ease-out for context, but avoid the noticeable lag
                // that a default/long popup transition introduces on macOS.
                duration: Duration(milliseconds: 48),
                reverseDuration: Duration(milliseconds: 36),
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeOutCubic,
              ),
        items: actions.map((action) {
          final permitted = _permitted(action);
          final available = permitted && action.unavailableMessage == null;
          final explanation = !permitted
              ? '企业管理员已限制此应用'
              : action.unavailableMessage;
          return PopupMenuItem<String>(
            key: ValueKey('quick-create-${action.id}'),
            value: action.id,
            height: mobile ? 50 : 42,
            padding: EdgeInsets.symmetric(
              horizontal: mobile ? 12 : 16,
              vertical: mobile ? 4 : 0,
            ),
            child: Tooltip(
              message: explanation ?? action.label,
              child: Semantics(
                label: explanation == null
                    ? action.label
                    : '${action.label}，$explanation',
                excludeSemantics: true,
                child: Row(
                  children: [
                    Icon(
                      action.icon,
                      size: mobile ? 24 : 20,
                      color: const Color(0xff777c83),
                    ),
                    SizedBox(width: mobile ? 10 : 12),
                    Expanded(
                      child: Text(
                        action.label,
                        maxLines: mobile ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: mobile ? 17 : 14,
                          height: 1.2,
                          fontWeight: FontWeight.w400,
                          color: available ? inkColor : mutedColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      );
    } catch (_) {
      if (mounted && scope == widget.scopeKey) _explain('操作暂时未完成，请重试。');
      return;
    } finally {
      // Opening a menu is local UI work. A selected action may await a server
      // or another page, but that must not keep the + button locked afterwards.
      _opening = false;
    }
    if (!mounted ||
        !widget.enabled ||
        selected == null ||
        scope != widget.scopeKey) {
      return;
    }
    try {
      final action = widget.actions
          .where((item) => item.id == selected)
          .firstOrNull;
      if (action == null) return;
      if (!_permitted(action)) {
        _explain('企业管理员已限制此应用');
      } else if (action.unavailableMessage != null) {
        _explain(action.unavailableMessage!);
      } else {
        await widget.onSelected(action.id);
      }
    } catch (_) {
      if (mounted && scope == widget.scopeKey) _explain('操作暂时未完成，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: _anchor,
    tooltip: '新建与添加',
    onPressed: widget.enabled ? _show : null,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    icon: const Icon(Icons.add_circle_outline, size: 24),
  );
}
