import 'package:flutter/material.dart';

import '../message_groups.dart';
import 'office_theme.dart';

Future<void> showOfficeMessageGroupDialog(
  BuildContext context,
  OfficeMessageGroups controller, {
  required WidgetBuilder builder,
  bool useSafeArea = true,
}) {
  final identity = controller.identityKey;
  return showDialog<void>(
    context: context,
    useSafeArea: useSafeArea,
    builder: (dialogContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => controller.identityKey == identity
          ? builder(dialogContext)
          : AlertDialog(
              title: const Text('当前身份已变化'),
              content: const Text('请关闭此窗口，在当前身份下重新打开分组。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
              ],
            ),
    ),
  );
}

IconData officeMessageGroupIcon(Json group) => group['type'] == 'label'
    ? Icons.label_outline
    : const {
            'messages': Icons.chat_bubble_outline,
            'unread': Icons.mark_chat_unread_outlined,
            'marked': Icons.flag_outlined,
            'mentions': Icons.alternate_email,
            'direct': Icons.person_outline,
            'groups': Icons.group_outlined,
            'labels': Icons.label_outline,
            'documents': Icons.file_present_outlined,
            'topics': Icons.forum_outlined,
            'muted': Icons.notifications_off_outlined,
            'agents': Icons.auto_awesome_outlined,
            'completed': Icons.check_circle_outline,
          }[group['id']] ??
          Icons.folder_outlined;

/// Licensed library glyphs keep the mobile group icons consistent with the
/// rounded message/list controls. The source files and license live with them.
Widget officeMessageGroupGraphic(Json group, {double size = 22, Color? color}) {
  final asset = const {
    'messages': 'chat-circle-text',
    'unread': 'solar-chat-round-unread-linear',
    'marked': 'tabler-flag-3',
    'mentions': 'at-line',
    'documents': 'file-cloud-line',
    'topics': 'tabler-message-2',
    'completed': 'solar-chat-round-check-linear',
  }[group['id']];
  return asset == null
      ? Icon(
          officeMessageGroupIcon(group),
          // Material's bust glyphs have more inset than the library PNGs.
          size: const {'direct', 'groups'}.contains(group['id'])
              ? size * 26 / 22
              : size,
          color: color,
        )
      : Image.asset(
          'assets/message_groups/$asset.png',
          width: size,
          height: size,
          color: color,
          filterQuality: FilterQuality.high,
          excludeFromSemantics: true,
        );
}

class OfficeMessageGroupPanel extends StatefulWidget {
  const OfficeMessageGroupPanel({
    super.key,
    required this.controller,
    required this.onSelected,
    required this.onManage,
    required this.onCreateLabel,
    this.onClose,
    this.mobile = false,
  });
  final OfficeMessageGroups controller;
  final ValueChanged<String> onSelected;
  final VoidCallback onManage, onCreateLabel;
  final VoidCallback? onClose;
  final bool mobile;
  @override
  State<OfficeMessageGroupPanel> createState() =>
      _OfficeMessageGroupPanelState();
}

class _OfficeMessageGroupPanelState extends State<OfficeMessageGroupPanel> {
  late bool _labelsOpen;
  @override
  void initState() {
    super.initState();
    _labelsOpen = !widget.mobile;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final builtins = c.visible
          .where((group) => group['type'] == 'builtin')
          .toList();
      final labels = c.visible
          .where((group) => group['type'] == 'label')
          .toList();
      // Older endpoints supplied only label children. Keep their existing
      // container until their first version-2 response provides its real ID.
      final topLevel = c.group('labels') != null
          ? builtins
          : <Json>[
              ...builtins.take(4),
              if (c.loaded) {'id': 'labels', 'name': '标签', 'type': 'builtin'},
              ...builtins.skip(4),
            ];
      Widget row(Json group) => Padding(
        key: ValueKey('message-group-row-${group['id']}'),
        padding: widget.mobile
            ? const EdgeInsets.symmetric(vertical: 1)
            : EdgeInsets.zero,
        child: Material(
          color: c.selectedId == group['id']
              ? widget.mobile
                    ? const Color(0xffe9efff)
                    : selectedColor
              : Colors.transparent,
          borderRadius: BorderRadius.circular(widget.mobile ? 6 : 5),
          child: InkWell(
            onTap: group['available'] == false
                ? null
                : () => widget.onSelected(str(group['id'])),
            child: Container(
              height: widget.mobile ? 47 : null,
              padding: widget.mobile
                  ? EdgeInsets.only(
                      left: group['type'] == 'label' ? 26 : 14,
                      right: 14,
                    )
                  : const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  if (widget.mobile)
                    SizedBox(
                      width: 24,
                      child: officeMessageGroupGraphic(
                        group,
                        color: c.selectedId == group['id']
                            ? accentColor
                            : const Color(0xff767c82),
                      ),
                    )
                  else
                    Icon(
                      officeMessageGroupIcon(group),
                      size: 18,
                      color: c.selectedId == group['id']
                          ? accentColor
                          : mutedColor,
                    ),
                  SizedBox(width: widget.mobile ? 12 : 9),
                  Expanded(
                    child: Text(
                      str(group['name']),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: widget.mobile ? 17 : 12,
                        height: widget.mobile ? 1.25 : null,
                        fontWeight: widget.mobile && c.selectedId == group['id']
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: c.selectedId == group['id']
                            ? accentColor
                            : widget.mobile
                            ? const Color(0xff767c82)
                            : inkColor,
                      ),
                    ),
                  ),
                  if (!widget.mobile &&
                      (group['unread_count'] as num? ?? 0) > 0)
                    Text(
                      '${group['unread_count']}',
                      style: const TextStyle(fontSize: 10, color: mutedColor),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      Widget labelsSection() => Column(
        key: const ValueKey('message-group-labels-container'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.mobile)
            Semantics(
              button: true,
              expanded: _labelsOpen,
              child: InkWell(
                key: const ValueKey('message-groups-labels-toggle'),
                onTap: () => setState(() => _labelsOpen = !_labelsOpen),
                child: SizedBox(
                  height: 49,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(
                          _labelsOpen
                              ? Icons.arrow_drop_down
                              : Icons.arrow_right,
                          size: 24,
                          color: const Color(0xff767c82),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          '标签',
                          style: TextStyle(
                            fontSize: 17,
                            height: 1.25,
                            color: Color(0xff767c82),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => setState(() => _labelsOpen = !_labelsOpen),
                    icon: Icon(
                      _labelsOpen ? Icons.expand_more : Icons.chevron_right,
                      size: 17,
                    ),
                    label: const Text('标签', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: mutedColor,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '新建标签',
                  onPressed: widget.onCreateLabel,
                  icon: const Icon(Icons.add, size: 17),
                ),
              ],
            ),
          if (_labelsOpen) ...[
            ...labels.map(row),
            if (widget.mobile)
              InkWell(
                key: const ValueKey('message-groups-create-label'),
                onTap: c.loaded ? widget.onCreateLabel : null,
                child: const SizedBox(
                  height: 49,
                  child: Padding(
                    padding: EdgeInsets.only(left: 26, right: 14),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: Icon(Icons.add, size: 20, color: accentColor),
                        ),
                        SizedBox(width: 12),
                        Text(
                          '新建标签',
                          style: TextStyle(fontSize: 15, color: accentColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (labels.isEmpty && !widget.mobile)
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 8, 12),
                child: Text(
                  '按项目整理会话',
                  style: TextStyle(fontSize: 10, color: mutedColor),
                ),
              ),
          ],
        ],
      );
      return Material(
        color: Colors.white,
        child: Column(
          children: [
            Padding(
              padding: widget.mobile
                  ? const EdgeInsets.fromLTRB(26, 4, 12, 5)
                  : const EdgeInsets.fromLTRB(7, 10, 8, 10),
              child: Row(
                children: [
                  if (!widget.mobile && widget.onClose != null)
                    IconButton(
                      key: const ValueKey('message-groups-close'),
                      tooltip: '收起消息分组',
                      onPressed: widget.onClose,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(32, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.menu, color: mutedColor, size: 20),
                    ),
                  Expanded(
                    child: GestureDetector(
                      onLongPress: c.loaded ? widget.onManage : null,
                      onSecondaryTap: c.loaded ? widget.onManage : null,
                      child: Text(
                        '分组',
                        key: const ValueKey('message-groups-title'),
                        style: TextStyle(
                          fontSize: widget.mobile ? 20 : 15,
                          height: widget.mobile ? 1.2 : null,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('message-groups-manage'),
                    tooltip: '编辑消息分组',
                    onPressed: c.loaded ? widget.onManage : null,
                    constraints: widget.mobile
                        ? null
                        : const BoxConstraints.tightFor(width: 32, height: 32),
                    style: widget.mobile
                        ? null
                        : IconButton.styleFrom(
                            minimumSize: const Size(32, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                    padding: widget.mobile ? null : EdgeInsets.zero,
                    icon: widget.mobile
                        ? Image.asset(
                            'assets/message_groups/list-settings-line.png',
                            width: 24,
                            height: 24,
                            color: const Color(0xff646a73),
                            filterQuality: FilterQuality.high,
                            excludeFromSemantics: true,
                          )
                        : const Icon(Icons.settings_outlined, size: 18),
                  ),
                ],
              ),
            ),
            if (c.loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                padding: widget.mobile
                    ? const EdgeInsets.fromLTRB(10, 0, 8, 16)
                    : const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  if (!c.loaded && !c.loading) ...[
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('分组暂不可用', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: c.refresh,
                      child: const Text('重新读取分组'),
                    ),
                  ],
                  for (final group in topLevel)
                    if (group['id'] == 'labels')
                      labelsSection()
                    else
                      row(group),
                  if (c.error != null && c.loaded)
                    TextButton(
                      onPressed: c.refresh,
                      child: const Text(
                        '同步失败，点击重试',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
