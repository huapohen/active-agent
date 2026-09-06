import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'office_theme.dart';

List<(String, String, IconData)> officeMessageActions(
  Json message,
  bool own,
) => [
  ('reply', '回复', Icons.reply_outlined),
  ('copy', '复制', Icons.copy_outlined),
  ('forward', '转发', Icons.forward_outlined),
  ('pin', message['pinned'] == true ? '取消置顶' : '置顶消息', Icons.push_pin_outlined),
  ('read', '阅读状态', Icons.done_all),
  ('original', '查看原文', Icons.article_outlined),
  if (own) ('edit', '编辑消息', Icons.edit_outlined),
  if (own) ('retract', '撤回消息', Icons.undo),
];

Future<String?> showOfficeMessageActions(
  BuildContext context,
  Json message, {
  required bool own,
  Offset? position,
}) {
  final actions = officeMessageActions(message, own);
  if (MediaQuery.sizeOf(context).width < 720) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceEvenly,
                    children: [
                      for (final emoji in ['👍', '❤️', '🎉', '👀', '✅', '🙏'])
                        IconButton(
                          tooltip: '回应 $emoji',
                          onPressed: () =>
                              Navigator.pop(context, 'react:$emoji'),
                          icon: Text(
                            emoji,
                            style: const TextStyle(fontSize: 23),
                          ),
                        ),
                    ],
                  ),
                  const Divider(),
                  GridView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount:
                          MediaQuery.sizeOf(context).width < 360 &&
                              MediaQuery.textScalerOf(context).scale(12) > 16
                          ? 3
                          : 4,
                      mainAxisExtent:
                          60 + MediaQuery.textScalerOf(context).scale(12) * 2,
                    ),
                    children: [
                      for (final item in actions)
                        InkWell(
                          onTap: () => Navigator.pop(context, item.$1),
                          borderRadius: BorderRadius.circular(8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                item.$3,
                                color: item.$1 == 'retract'
                                    ? Colors.redAccent
                                    : accentColor,
                              ),
                              const SizedBox(height: 9),
                              Text(
                                item.$2,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final point =
      position ?? overlay.localToGlobal(overlay.size.center(Offset.zero));
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(
        overlay.globalToLocal(point),
        overlay.globalToLocal(point),
      ),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final item in actions)
        PopupMenuItem(
          value: item.$1,
          child: Row(
            children: [
              Icon(item.$3, size: 18),
              const SizedBox(width: 12),
              Text(item.$2),
            ],
          ),
        ),
      const PopupMenuDivider(),
      for (final emoji in ['👍', '❤️', '🎉', '👀', '✅', '🙏'])
        PopupMenuItem(value: 'react:$emoji', child: Text(emoji)),
    ],
  );
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
