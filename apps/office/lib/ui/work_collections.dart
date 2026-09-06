import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class WorkDocuments extends StatefulWidget {
  const WorkDocuments({super.key, required this.state, this.heading = true});
  final OfficeState state;
  final bool heading;
  @override
  State<WorkDocuments> createState() => _WorkDocumentsState();
}

class _WorkDocumentsState extends State<WorkDocuments> {
  bool _currentOnly = false;
  String _query = '';
  OfficeState get state => widget.state;
  Future<void> _open(Json doc) async {
    try {
      await OfficeDialogs.document(context, state, doc);
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  String _location(Json doc) {
    final ids = (doc['room_ids'] as List? ?? [state.selectedRoomId])
        .map((e) => e.toString())
        .toList();
    return officeBusinessRooms(state)
        .where((r) => ids.contains(r['id']))
        .map((r) => str(r['name']))
        .join('、');
  }

  @override
  Widget build(BuildContext context) {
    final docs =
        (widget.heading ? state.allDocuments : maps(state.detail?['documents']))
            .where(
              (d) =>
                  str(d['title'])
                      .toLowerCase()
                      .contains(_query.toLowerCase()) &&
                  (!_currentOnly ||
                      (d['room_ids'] as List? ?? [state.selectedRoomId])
                          .contains(state.selectedRoomId)),
            )
            .toList()
          ..sort(
            (a, b) => str(b['updated_at']).compareTo(str(a['updated_at'])),
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 620;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 25, 26, 18),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.heading ? '主页' : '共同文档',
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (wide)
                    SizedBox(
                      width: 190,
                      child: OfficeSearch(
                        hint: '查找文档',
                        onChanged: (q) => setState(() => _query = q),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.heading)
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 0, 26, 22),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    _creationCard(
                      Icons.note_add_outlined,
                      '新建文档',
                      '选择工作会话，共同创作',
                      () => OfficeDialogs.document(context, state),
                    ),
                    _creationCard(
                      Icons.ios_share_outlined,
                      '导出工作资料',
                      '携带讨论、文档与依据',
                      state.selectedRoomId == null ||
                              !state.moduleAvailable('im')
                          ? null
                          : () => OfficeDialogs.export(context, state),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 0, 26, 15),
                child: FilledButton.icon(
                  onPressed: () => OfficeDialogs.document(context, state),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建共同文档'),
                ),
              ),
            if (!wide)
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 0, 26, 15),
                child: OfficeSearch(
                  hint: '查找文档',
                  onChanged: (q) => setState(() => _query = q),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() => _currentOnly = false),
                    child: Text(
                      '最近更新',
                      style: TextStyle(
                        color: !_currentOnly ? accentColor : mutedColor,
                        fontWeight: !_currentOnly
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (widget.heading)
                    TextButton(
                      onPressed: () => setState(() => _currentOnly = true),
                      child: Text(
                        '当前会话',
                        style: TextStyle(
                          color: _currentOnly ? accentColor : mutedColor,
                          fontWeight: _currentOnly
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  const Spacer(),
                  Text(
                    '${docs.length} 份文档',
                    style: const TextStyle(fontSize: 10, color: mutedColor),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (wide)
              const Padding(
                padding: EdgeInsets.fromLTRB(29, 15, 30, 15),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        '标题',
                        style: TextStyle(fontSize: 10, color: mutedColor),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        '位置',
                        style: TextStyle(fontSize: 10, color: mutedColor),
                      ),
                    ),
                    Expanded(
                      flex: 1,
                      child: Text(
                        '版本',
                        style: TextStyle(fontSize: 10, color: mutedColor),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        '更新时间',
                        style: TextStyle(fontSize: 10, color: mutedColor),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: docs.isEmpty
                  ? EmptyOffice(
                      title: '文档，是共同的工作现场',
                      subtitle: state.rooms.isEmpty
                          ? '创建一个工作会话，开始第一份共同文档。'
                          : '选择工作会话，把背景、方案与成果写进文档。',
                      icon: Icons.description_outlined,
                    )
                  : ListView.separated(
                      padding: EdgeInsets.symmetric(horizontal: wide ? 25 : 18),
                      itemCount: docs.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final doc = docs[index];
                        return InkWell(
                          onTap: () => _open(doc),
                          borderRadius: BorderRadius.circular(5),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: wide ? 17 : 15,
                            ),
                            child: wide
                                ? Row(
                                    children: [
                                      Expanded(
                                        flex: 5,
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.description,
                                              color: Color(0xff5589ed),
                                              size: 21,
                                            ),
                                            const SizedBox(width: 11),
                                            Expanded(
                                              child: Text(
                                                str(doc['title']),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Expanded(
                                        flex: 3,
                                        child: Text(
                                          _location(doc),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: mutedColor,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 1,
                                        child: Text(
                                          'r${doc['revision']}',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: mutedColor,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          clockText(
                                            doc['updated_at'],
                                            date: true,
                                          ),
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: mutedColor,
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      const Icon(
                                        Icons.description,
                                        color: Color(0xff5589ed),
                                        size: 28,
                                      ),
                                      const SizedBox(width: 13),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              str(doc['title']),
                                              style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              '${_location(doc)} · r${doc['revision']}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: mutedColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Icon(
                                        Icons.chevron_right,
                                        size: 18,
                                        color: mutedColor,
                                      ),
                                    ],
                                  ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _creationCard(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback? action,
  ) => SizedBox(
    width: 210,
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(7),
        side: const BorderSide(color: Color(0xffe5e8ee)),
      ),
      child: InkWell(
        onTap: action,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                icon,
                color: action == null ? mutedColor : accentColor,
                size: 25,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 9, color: mutedColor),
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

class WorkTaskLibrary extends StatelessWidget {
  const WorkTaskLibrary({super.key, required this.state});
  final OfficeState state;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(25),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '任务',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton.icon(
              onPressed: () => OfficeDialogs.task(context, state),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建任务'),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(25, 0, 25, 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '已加入会话中的全部任务 · ${state.allTasks.length} 项',
            style: const TextStyle(fontSize: 11, color: mutedColor),
          ),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: state.allTasks.isEmpty
            ? const EmptyOffice(
                title: '把讨论变成行动',
                subtitle: '在工作会话中明确负责人、目标与验收条件。',
                icon: Icons.task_alt,
              )
            : ListView.separated(
                padding: const EdgeInsets.all(22),
                itemCount: state.allTasks.length,
                separatorBuilder: (_, _) => const Divider(height: 20),
                itemBuilder: (context, index) {
                  final task = state.allTasks[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      task['status'] == 'done'
                          ? Icons.check_circle_outline
                          : Icons.radio_button_unchecked,
                      size: 22,
                      color: task['status'] == 'done'
                          ? const Color(0xff55ad83)
                          : const Color(0xffb4bdcd),
                    ),
                    title: Text(
                      str(task['title']),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(
                        '${str(task['room_name'])} · ${statusName(task['status'])}',
                        style: const TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: mutedColor,
                    ),
                    onTap: () async {
                      try {
                        await openTask(context, state, task);
                      } catch (e) {
                        if (context.mounted) {
                          notifyOffice(context, friendlyError(e));
                        }
                      }
                    },
                  );
                },
              ),
      ),
    ],
  );

  static Future<void> openTask(
    BuildContext context,
    OfficeState state,
    Json task,
  ) => showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(18),
      backgroundColor: Colors.white,
      child: SizedBox(
        width: 730,
        height: MediaQuery.sizeOf(dialogContext).height * .8,
        child: AnimatedBuilder(
          animation: state,
          builder: (_, _) {
            final current =
                state.allTasks
                    .where((t) => t['id'] == task['id'])
                    .firstOrNull ??
                task;
            return Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    tooltip: '关闭任务',
                    icon: const Icon(Icons.close),
                  ),
                ),
                Expanded(
                  child: WorkTasks(
                    state: state,
                    tasks: [current],
                    people: officeRoomPeople(state, str(task['room_id'])),
                    showCreate: false,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class WorkTasks extends StatelessWidget {
  const WorkTasks({
    super.key,
    required this.state,
    this.tasks,
    this.people,
    this.showCreate = true,
  });
  final OfficeState state;
  final List<Json>? tasks, people;
  final bool showCreate;
  @override
  Widget build(BuildContext context) {
    final tasks = this.tasks ?? maps(state.detail?['tasks']);
    final people = this.people ?? maps(state.detail?['members']);
    if (state.detail == null && this.tasks == null) {
      return const EmptyOffice(
        title: '明确下一步，共同推进',
        subtitle: '选择一个工作会话，查看和分配工作任务。',
        icon: Icons.task_alt_outlined,
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(25, 21, 25, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '工作任务',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${tasks.where((t) => t['status'] == 'done').length} / ${tasks.length} 项已完成 · 人和 Agent 都能负责与交付',
                      style: const TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ],
                ),
              ),
              if (showCreate)
                FilledButton.icon(
                  onPressed: () => OfficeDialogs.task(context, state),
                  icon: const Icon(Icons.add, size: 17),
                  label: const Text('新建'),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? const EmptyOffice(
                  title: '把讨论变成行动',
                  subtitle: '添加具体任务，明确负责人和验收条件。',
                  icon: Icons.task_alt_outlined,
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final done = task['status'] == 'done';
                    return Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        border: Border.all(color: borderColor),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 23,
                                height: 23,
                                child: Checkbox(
                                  value: done,
                                  side: const BorderSide(
                                    color: Color(0xffc6cbd4),
                                  ),
                                  onChanged: (_) async {
                                    try {
                                      await state.updateTask(
                                        task,
                                        status: done ? 'open' : 'done',
                                      );
                                    } catch (e) {
                                      if (context.mounted) {
                                        notifyOffice(context, friendlyError(e));
                                      }
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  str(task['title']),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    decoration: done
                                        ? TextDecoration.lineThrough
                                        : null,
                                    color: done ? mutedColor : inkColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (str(task['description']).isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(32, 9, 0, 10),
                              child: Text(
                                str(task['description']),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: mutedColor,
                                  height: 1.8,
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(left: 32),
                            child: Wrap(
                              spacing: 18,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                DropdownButton<String>(
                                  isDense: true,
                                  value:
                                      people.any(
                                        (p) =>
                                            personId(p) == task['assignee_id'],
                                      )
                                      ? str(task['assignee_id'])
                                      : '',
                                  underline: const SizedBox(),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: mutedColor,
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                      value: '',
                                      child: Text('待分配'),
                                    ),
                                    ...people.map(
                                      (p) => DropdownMenuItem(
                                        value: personId(p),
                                        child: Text(
                                          '${str(p['name'])}${p['kind'] == 'agent' ? ' · Agent' : ''}',
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (v) async {
                                    try {
                                      await state.updateTask(
                                        task,
                                        assigneeId: v ?? '',
                                      );
                                    } catch (e) {
                                      if (context.mounted) {
                                        notifyOffice(context, friendlyError(e));
                                      }
                                    }
                                  },
                                ),
                                DropdownButton<String>(
                                  isDense: true,
                                  value: str(task['status'], 'open'),
                                  underline: const SizedBox(),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: accentColor,
                                  ),
                                  items: ['open', 'doing', 'done']
                                      .map(
                                        (v) => DropdownMenuItem(
                                          value: v,
                                          child: Text(statusName(v)),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) async {
                                    try {
                                      await state.updateTask(task, status: v);
                                    } catch (e) {
                                      if (context.mounted) {
                                        notifyOffice(context, friendlyError(e));
                                      }
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class Workbench extends StatelessWidget {
  const Workbench({
    super.key,
    required this.state,
    required this.onDocuments,
    required this.onTasks,
  });
  final OfficeState state;
  final VoidCallback onDocuments, onTasks;
  @override
  Widget build(BuildContext context) {
    final tasks = maps(state.detail?['tasks']),
        docs = maps(state.detail?['documents']),
        runs = maps(state.detail?['runs']);
    final room = state.detail?['room'] as Map?;
    return ListView(
      padding: const EdgeInsets.all(26),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '工作台',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              clockText(DateTime.now().toIso8601String(), date: true),
              style: const TextStyle(fontSize: 11, color: mutedColor),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '你好，${str(state.me?['name'])}。让每一次讨论都有清楚的下一步。',
          style: const TextStyle(fontSize: 12, color: mutedColor),
        ),
        const SizedBox(height: 27),
        LayoutBuilder(
          builder: (context, c) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _metric(
                '工作会话',
                state.rooms.length,
                Icons.forum_outlined,
                c.maxWidth,
              ),
              _metric(
                '当前会话待办',
                tasks.where((t) => t['status'] != 'done').length,
                Icons.task_alt,
                c.maxWidth,
                onTap: onTasks,
              ),
              _metric(
                '当前共同文档',
                docs.length,
                Icons.description_outlined,
                c.maxWidth,
                onTap: onDocuments,
              ),
            ],
          ),
        ),
        const SizedBox(height: 29),
        const Text(
          '共同目标',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xfff5f8ff),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                str(room?['name'], '选择一个工作会话'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                str(room?['description'], '把背景、共识和成果保留在共同文档里。'),
                style: const TextStyle(
                  fontSize: 12,
                  color: mutedColor,
                  height: 1.8,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 27),
        const Text(
          'Agent 工作记录',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        const Text(
          '每一次工作的输入、依据和交付，都可以查看与追溯。',
          style: TextStyle(fontSize: 11, color: mutedColor),
        ),
        const SizedBox(height: 14),
        if (runs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              '当前会话暂时没有 Agent 工作记录。',
              style: TextStyle(fontSize: 12, color: mutedColor),
            ),
          ),
        ...runs.reversed.map((run) {
          final result = run['result'] is Map ? run['result'] as Map : {};
          final artifact = result['artifact'] is Map
              ? result['artifact'] as Map
              : null;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome_outlined,
                      size: 18,
                      color: Color(0xff7b86be),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        statusName(run['status']),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Text(
                      clockText(run['created_at'], date: true),
                      style: const TextStyle(fontSize: 10, color: mutedColor),
                    ),
                  ],
                ),
                if (result['rationale'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      str(result['rationale']),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        height: 1.8,
                      ),
                    ),
                  ),
                if (artifact != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 11),
                    child: Text(
                      '▱ ${str(artifact['title'])}',
                      style: const TextStyle(fontSize: 12, color: accentColor),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () =>
                        OfficeDialogs.run(context, state, str(run['id'])),
                    child: const Text('查看依据与成果 →'),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _metric(
    String label,
    int number,
    IconData icon,
    double width, {
    VoidCallback? onTap,
  }) => SizedBox(
    width: width > 600
        ? (width - 24) / 3
        : width > 380
        ? (width - 12) / 2
        : width,
    child: Material(
      color: const Color(0xfff7f8fc),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 19, color: const Color(0xff98a4c3)),
                  const Spacer(),
                  Text(
                    '$number',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                label,
                style: const TextStyle(fontSize: 11, color: mutedColor),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
