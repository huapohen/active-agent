import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeAppWorkbench extends StatefulWidget {
  const OfficeAppWorkbench({
    super.key,
    required this.state,
    required this.onOpen,
  });
  final OfficeState state;
  final ValueChanged<String> onOpen;
  @override
  State<OfficeAppWorkbench> createState() => _OfficeAppWorkbenchState();
}

class _OfficeAppWorkbenchState extends State<OfficeAppWorkbench> {
  String _query = '';
  OfficeState get s => widget.state;
  IconData _icon(String id) =>
      const {
        'messages': Icons.chat_bubble_outline,
        'documents': Icons.description_outlined,
        'tasks': Icons.task_alt,
        'agents': Icons.auto_awesome_outlined,
        'calendar': Icons.calendar_month_outlined,
        'meetings': Icons.videocam_outlined,
        'contacts': Icons.contacts_outlined,
        'approvals': Icons.fact_check_outlined,
        'reports': Icons.bar_chart_outlined,
        'minutes': Icons.graphic_eq,
      }[id] ??
      Icons.apps;
  Color _color(String id) =>
      const {
        'messages': Color(0xff5791f2),
        'documents': Color(0xff5791f2),
        'tasks': Color(0xfff1a55a),
        'agents': Color(0xff9a7cdb),
        'calendar': Color(0xffeb8b91),
        'meetings': Color(0xff58a3dc),
        'contacts': Color(0xff73aea2),
        'minutes': Color(0xff8e77c5),
      }[id] ??
      const Color(0xff9fa8ba);
  Future<void> _favorites({bool sorting = false}) async {
    final ids = [...s.appFavorites];
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text(
            sorting ? '排列常用应用' : '添加常用应用',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 430,
            height: 380,
            child: sorting
                ? ReorderableListView(
                    onReorderItem: (old, next) => change(() {
                      ids.insert(next, ids.removeAt(old));
                    }),
                    children: ids.map((id) {
                      final app =
                          s.apps.where((a) => a['id'] == id).firstOrNull ?? {};
                      return ListTile(
                        key: ValueKey(id),
                        leading: Icon(_icon(id), color: _color(id)),
                        title: Text(
                          str(app['name'], id),
                          style: const TextStyle(fontSize: 13),
                        ),
                        trailing: const Icon(
                          Icons.drag_handle,
                          color: mutedColor,
                        ),
                      );
                    }).toList(),
                  )
                : ListView(
                    children: s.apps.where((a) => a['available'] == true).map((
                      app,
                    ) {
                      final id = str(app['id']);
                      return CheckboxListTile(
                        value: ids.contains(id),
                        onChanged: (selected) => change(() {
                          selected == true ? ids.add(id) : ids.remove(id);
                        }),
                        secondary: Icon(_icon(id), color: _color(id)),
                        title: Text(
                          str(app['name']),
                          style: const TextStyle(fontSize: 13),
                        ),
                      );
                    }).toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      change(() => busy = true);
                      try {
                        await s.setAppFavorites(ids);
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (e) {
                        if (dialogContext.mounted) {
                          change(() => busy = false);
                          notifyOffice(context, friendlyError(e));
                        }
                      }
                    },
              child: Text(busy ? '正在保存…' : '保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth > 760;
      final favorites = s.appFavorites
          .map((id) => s.apps.where((a) => a['id'] == id).firstOrNull)
          .whereType<Json>()
          .where((a) => str(a['name']).contains(_query))
          .toList();
      final all = s.apps.where((a) => str(a['name']).contains(_query)).toList();
      return ListView(
        padding: EdgeInsets.all(desktop ? 27 : 20),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '工作台',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(
                width: desktop ? 210 : 130,
                child: OfficeSearch(
                  hint: '搜索应用',
                  onChanged: (q) => setState(() => _query = q),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  height: desktop ? 157 : 132,
                  padding: EdgeInsets.all(desktop ? 27 : 21),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xffe9efff), Color(0xfff0edfc)],
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '人机 · 共同推进每一项工作',
                              style: TextStyle(
                                fontSize: desktop ? 21 : 17,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xff43547b),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '消息、文档、任务与日程相连\n人和 Agent，共享一个工作现场',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xff8c99b6),
                                height: 1.85,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (desktop)
                        const Icon(
                          Icons.hub_outlined,
                          size: 61,
                          color: Color(0xffb4c5ee),
                        ),
                    ],
                  ),
                ),
              ),
              if (desktop) ...[
                const SizedBox(width: 17),
                Expanded(
                  child: Container(
                    height: 157,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '工作空间概况',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          '${s.rooms.length} 个工作会话',
                          style: const TextStyle(
                            fontSize: 11,
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${s.allDocuments.length} 份共同文档 · ${s.allTasks.where((t) => t['status'] != 'done').length} 项待办',
                          style: const TextStyle(
                            fontSize: 11,
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${s.meetings.where((m) => m['status'] != 'ended').length} 场待进行会议',
                          style: const TextStyle(
                            fontSize: 11,
                            color: mutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 27),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '我的常用',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                onPressed: () => _favorites(),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('添加'),
              ),
              TextButton(
                onPressed: favorites.length < 2
                    ? null
                    : () => _favorites(sorting: true),
                child: const Text('排序'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (favorites.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xfff7f8fb),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '添加常用应用，让每天的工作更顺手。',
                style: TextStyle(fontSize: 12, color: mutedColor),
              ),
            )
          else
            _grid(
              favorites,
              desktop,
              constraints.maxWidth - (desktop ? 54 : 40),
            ),
          const SizedBox(height: 31),
          const Text(
            '工作空间应用',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 17),
          _grid(
            all.where((a) => a['available'] == true).toList(),
            desktop,
            constraints.maxWidth - (desktop ? 54 : 40),
          ),
          if (all.any((a) => a['available'] != true)) ...[
            const SizedBox(height: 28),
            const Text(
              '规划中的能力',
              style: TextStyle(fontSize: 12, color: mutedColor),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: all
                  .where((a) => a['available'] != true)
                  .map(
                    (a) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xfff7f8fa),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${str(a['name'])} · 尚未实现',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xffa7afbc),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      );
    },
  );
  Widget _grid(List<Json> apps, bool desktop, double width) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    itemCount: apps.length,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 4,
      crossAxisSpacing: desktop ? 13 : 6,
      mainAxisSpacing: desktop ? 13 : 14,
      childAspectRatio: desktop ? 2.6 : .93,
    ),
    itemBuilder: (context, index) {
      final app = apps[index], id = str(app['id']);
      final icon = Container(
        width: desktop ? 34 : 40,
        height: desktop ? 34 : 40,
        decoration: BoxDecoration(
          color: _color(id),
          borderRadius: BorderRadius.circular(desktop ? 9 : 11),
        ),
        child: Icon(_icon(id), size: desktop ? 20 : 23, color: Colors.white),
      );
      return Material(
        color: Colors.white,
        shape: desktop
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: borderColor),
              )
            : null,
        child: InkWell(
          onTap: app['available'] == true
              ? () => widget.onOpen(str(app['route'], id))
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.all(desktop ? 13 : 3),
            child: desktop
                ? Row(
                    children: [
                      icon,
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          str(app['name']),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      icon,
                      const SizedBox(height: 10),
                      Text(
                        str(app['name']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10, height: 1.5),
                      ),
                    ],
                  ),
          ),
        ),
      );
    },
  );
}
