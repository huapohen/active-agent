import 'package:flutter/material.dart';

import '../message_groups.dart';
import 'office_theme.dart';

Future<void> showOfficeMessageGroupDialog(
  BuildContext context,
  OfficeMessageGroups controller, {
  required WidgetBuilder builder,
}) {
  final identity = controller.identityKey;
  return showDialog<void>(
    context: context,
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
            'muted': Icons.notifications_off_outlined,
            'agents': Icons.auto_awesome_outlined,
            'completed': Icons.check_circle_outline,
          }[group['id']] ??
          Icons.folder_outlined;

class OfficeMessageGroupPanel extends StatefulWidget {
  const OfficeMessageGroupPanel({
    super.key,
    required this.controller,
    required this.onSelected,
    required this.onManage,
    required this.onCreateLabel,
  });
  final OfficeMessageGroups controller;
  final ValueChanged<String> onSelected;
  final VoidCallback onManage, onCreateLabel;
  @override
  State<OfficeMessageGroupPanel> createState() =>
      _OfficeMessageGroupPanelState();
}

class _OfficeMessageGroupPanelState extends State<OfficeMessageGroupPanel> {
  bool _labelsOpen = true;
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
      Widget row(Json group) => Material(
        color: c.selectedId == group['id'] ? selectedColor : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: group['available'] == false
              ? null
              : () => widget.onSelected(str(group['id'])),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Icon(
                  officeMessageGroupIcon(group),
                  size: 18,
                  color: c.selectedId == group['id'] ? accentColor : mutedColor,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    str(group['name']),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: c.selectedId == group['id']
                          ? accentColor
                          : inkColor,
                    ),
                  ),
                ),
                if ((group['unread_count'] as num? ?? 0) > 0)
                  Text(
                    '${group['unread_count']}',
                    style: const TextStyle(fontSize: 10, color: mutedColor),
                  ),
              ],
            ),
          ),
        ),
      );
      return Material(
        color: Colors.white,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '分组',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '编辑消息分组',
                    onPressed: c.loaded ? widget.onManage : null,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                  ),
                ],
              ),
            ),
            if (c.loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
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
                  ...builtins.take(4).map(row),
                  if (c.loaded) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _labelsOpen = !_labelsOpen),
                            icon: Icon(
                              _labelsOpen
                                  ? Icons.expand_more
                                  : Icons.chevron_right,
                              size: 17,
                            ),
                            label: const Text(
                              '标签',
                              style: TextStyle(fontSize: 12),
                            ),
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
                      if (labels.isEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(12, 0, 8, 12),
                          child: Text(
                            '按项目整理会话',
                            style: TextStyle(fontSize: 10, color: mutedColor),
                          ),
                        ),
                    ],
                  ],
                  ...builtins.skip(4).map(row),
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
