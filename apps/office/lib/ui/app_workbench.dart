import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeAppWorkbench extends StatefulWidget {
  const OfficeAppWorkbench({
    super.key,
    required this.state,
    required this.onOpen,
    this.embeddedMobileHeader = false,
  });
  final OfficeState state;
  final ValueChanged<String> onOpen;
  final bool embeddedMobileHeader;
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
        'docs': Icons.description_outlined,
        'tasks': Icons.task_alt,
        'agents': Icons.auto_awesome_outlined,
        'calendar': Icons.calendar_month_outlined,
        'meetings': Icons.videocam_outlined,
        'contacts': Icons.contacts_outlined,
        'approvals': Icons.fact_check_outlined,
        'reports': Icons.bar_chart_outlined,
        'minutes': Icons.graphic_eq,
        'mail': Icons.mail_outline,
        'attendance': Icons.location_on_outlined,
        'enterprise': Icons.apartment_outlined,
      }[id] ??
      Icons.apps;
  Color _color(String id) =>
      const {
        'messages': Color(0xff5791f2),
        'documents': Color(0xff5791f2),
        'docs': Color(0xff5791f2),
        'tasks': Color(0xfff1a55a),
        'agents': Color(0xff9a7cdb),
        'calendar': Color(0xffeb8b91),
        'meetings': Color(0xff58a3dc),
        'contacts': Color(0xff73aea2),
        'minutes': Color(0xff8e77c5),
        'attendance': Color(0xffff8b2d),
        'approvals': Color(0xfff59b3b),
        'mail': Color(0xff6da2da),
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
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 13,
                              mobile: 17,
                            ),
                          ),
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
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 13,
                              mobile: 17,
                            ),
                          ),
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
        padding: EdgeInsets.all(desktop ? 27 : 16),
        children: [
          if (desktop || !widget.embeddedMobileHeader)
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
          if (desktop || !widget.embeddedMobileHeader)
            const SizedBox(height: 24),
          if (!desktop) ...[
            const Text(
              '工作空间头条',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  height: desktop ? 157 : null,
                  constraints: desktop
                      ? null
                      : const BoxConstraints(minHeight: 132),
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
                            Text(
                              '消息、文档、任务与日程相连\n人和 Agent，共享一个工作现场',
                              style: TextStyle(
                                fontSize: officeFontSize(
                                  context,
                                  desktop: 11,
                                  mobile: 14,
                                ),
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
                        Text(
                          '工作空间概况',
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 13,
                              mobile: 17,
                            ),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          '${s.rooms.length} 个工作会话',
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 11,
                              mobile: 14,
                            ),
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${s.allDocuments.length} 份共同文档 · ${s.allTasks.where((t) => t['status'] != 'done').length} 项待办',
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 11,
                              mobile: 14,
                            ),
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${s.meetings.where((m) => m['status'] != 'ended').length} 场待进行会议',
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 11,
                              mobile: 14,
                            ),
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
              Expanded(
                child: Text(
                  '我的常用',
                  style: TextStyle(
                    fontSize: officeFontSize(context, desktop: 15, mobile: 17),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (desktop)
                TextButton.icon(
                  onPressed: () => _favorites(),
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('添加'),
                ),
              if (desktop)
                TextButton(
                  onPressed: favorites.length < 2
                      ? null
                      : () => _favorites(sorting: true),
                  child: const Text('排序'),
                ),
              if (!desktop) ...[
                IconButton(
                  key: const ValueKey('workbench-add-favorites'),
                  tooltip: '添加常用应用',
                  onPressed: () => _favorites(),
                  icon: const Icon(Icons.add, size: 21),
                ),
                IconButton(
                  key: const ValueKey('workbench-sort-favorites'),
                  tooltip: '排列常用应用',
                  onPressed: favorites.length < 2
                      ? null
                      : () => _favorites(sorting: true),
                  icon: const Icon(Icons.swap_vert, size: 21),
                ),
              ],
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
              child: Text(
                '添加常用应用，让每天的工作更顺手。',
                style: TextStyle(
                  fontSize: officeFontSize(context, desktop: 12, mobile: 14),
                  color: mutedColor,
                ),
              ),
            )
          else
            _grid(
              favorites,
              desktop,
              constraints.maxWidth - (desktop ? 54 : 32),
            ),
          const SizedBox(height: 31),
          Text(
            '工作空间应用',
            style: TextStyle(
              fontSize: officeFontSize(context, desktop: 15, mobile: 17),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 17),
          _grid(
            all.where((a) => a['available'] == true).toList(),
            desktop,
            constraints.maxWidth - (desktop ? 54 : 32),
          ),
          if (all.any((a) => a['available'] != true)) ...[
            const SizedBox(height: 28),
            Text(
              '规划中的能力',
              style: TextStyle(
                fontSize: officeFontSize(context, desktop: 12, mobile: 14),
                color: mutedColor,
              ),
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
                        style: TextStyle(
                          fontSize: officeFontSize(
                            context,
                            desktop: 10,
                            mobile: 12,
                          ),
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
      // Two app-label lines remain visible at narrow widths and the user's
      // chosen text scale; cell height must not shrink with its four-column width.
      mainAxisExtent: desktop
          ? null
          : 66 + MediaQuery.textScalerOf(context).scale(12) * 3,
    ),
    itemBuilder: (context, index) {
      final app = apps[index], id = str(app['id']);
      final icon = Container(
        key: ValueKey('workbench-app-icon-$id'),
        width: desktop ? 34 : 52,
        height: desktop ? 34 : 52,
        decoration: BoxDecoration(
          color: _color(id),
          borderRadius: BorderRadius.circular(desktop ? 9 : 13),
        ),
        child: Icon(_icon(id), size: desktop ? 20 : 30, color: Colors.white),
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
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 12,
                              mobile: 14,
                            ),
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
                      const SizedBox(height: 8),
                      Text(
                        str(app['name']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: officeFontSize(
                            context,
                            desktop: 10,
                            mobile: 12,
                          ),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      );
    },
  );
}
