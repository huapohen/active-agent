import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_theme.dart';

String friendlyError(Object error) => error
    .toString()
    .replaceFirst('OfficeException: ', '')
    .replaceFirst('Exception: ', '');

class OfficeDialogs {
  static final Map<String, Json> _documentDrafts = {};

  static Future<void> createRoom(
    BuildContext context,
    OfficeState state, {
    List<String> memberIds = const [],
  }) async {
    final title = TextEditingController(),
        description = TextEditingController();
    final members = memberIds.toSet()..remove(personId(state.me ?? {}));
    var busy = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text(
            '创建工作群',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: '群名称',
                      hintText: '例如：产品发布协作',
                    ),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: description,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '共同目标',
                      hintText: '写下这项工作的背景和目标',
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '邀请工作成员',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  ...state.principals
                      .where((p) => personId(p) != personId(state.me ?? {}))
                      .map(
                        (p) => CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: members.contains(personId(p)),
                          onChanged: (v) => change(() {
                            v == true
                                ? members.add(personId(p))
                                : members.remove(personId(p));
                          }),
                          title: Row(
                            children: [
                              PersonAvatar(
                                name: str(p['name']),
                                agent: p['kind'] == 'agent',
                                size: 28,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  str(p['name']),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              IdentityBadge(agent: p['kind'] == 'agent'),
                            ],
                          ),
                        ),
                      ),
                  if (error != null)
                    Text(
                      error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
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
                      if (title.text.trim().isEmpty) {
                        change(() => error = '请填写群名称');
                        return;
                      }
                      change(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await state.createRoom(
                          title.text.trim(),
                          description: description.text.trim(),
                          memberIds: members.toList(),
                        );
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (e) {
                        if (dialogContext.mounted) {
                          change(() {
                            error = friendlyError(e);
                            busy = false;
                          });
                        }
                      }
                    },
              child: Text(busy ? '正在创建…' : '创建工作群'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    description.dispose();
  }

  static Future<void> members(BuildContext context, OfficeState state) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final members = maps(state.detail?['members']);
          final self = members
              .where((m) => personId(m) == personId(state.me ?? {}))
              .firstOrNull;
          final owner = self?['role'] == 'owner';
          final available = state.principals
              .where((p) => !members.any((m) => personId(m) == personId(p)))
              .toList();
          return AlertDialog(
            title: Row(
              children: [
                const Expanded(
                  child: Text(
                    '会话成员',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${members.length} 人与 Agent',
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              ],
            ),
            content: SizedBox(
              width: 450,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...members.map(
                      (m) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            PersonAvatar(
                              name: str(m['name']),
                              agent: m['kind'] == 'agent',
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          str(m['name']),
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      IdentityBadge(
                                        agent: m['kind'] == 'agent',
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    m['role'] == 'owner' ? '会话负责人' : '工作成员',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: mutedColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (m['kind'] == 'agent' &&
                                (owner ||
                                    personId(m) == personId(state.me ?? {})))
                              DropdownButton<String>(
                                value: str(m['mode'], 'mentions'),
                                underline: const SizedBox(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: mutedColor,
                                ),
                                items: ['active', 'mentions', 'paused']
                                    .map(
                                      (mode) => DropdownMenuItem(
                                        value: mode,
                                        child: Text(statusName(mode)),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (mode) async {
                                  try {
                                    await state.setParticipation(
                                      personId(m),
                                      mode!,
                                    );
                                  } catch (e) {
                                    if (context.mounted) {
                                      notifyOffice(context, friendlyError(e));
                                    }
                                  }
                                },
                              )
                            else if (m['kind'] == 'agent')
                              Text(
                                statusName(m['mode']),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: mutedColor,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (owner &&
                        available.isNotEmpty &&
                        (state.detail?['room'] as Map?)?['kind'] !=
                            'direct') ...[
                      const Divider(height: 30),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '添加工作成员',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...available.map(
                        (p) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: PersonAvatar(
                            name: str(p['name']),
                            agent: p['kind'] == 'agent',
                            size: 30,
                          ),
                          title: Text(
                            str(p['name']),
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: TextButton(
                            onPressed: () async {
                              try {
                                await state.invite(personId(p));
                              } catch (e) {
                                if (context.mounted) {
                                  notifyOffice(context, friendlyError(e));
                                }
                              }
                            },
                            child: const Text('添加'),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 13),
                    const Text(
                      '人和 Agent 共享消息、文档与任务能力。参与方式控制 Agent 的自动工作节奏。',
                      style: TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        height: 1.8,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  static Future<void> task(
    BuildContext context,
    OfficeState state, {
    String? roomId,
  }) async {
    roomId ??= state.selectedRoomId ?? await chooseOfficeRoom(context, state);
    if (roomId == null || !context.mounted) return;
    final title = TextEditingController(),
        description = TextEditingController();
    String? assignee;
    String? error;
    var busy = false;
    final people = officeRoomPeople(state, roomId);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text(
            '新建任务',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: '任务名称',
                      hintText: '写下一个具体、可完成的行动',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: description,
                    minLines: 4,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: '目标与验收条件',
                      hintText: '要交付什么，如何判断完成？',
                    ),
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    initialValue: assignee ?? '',
                    decoration: const InputDecoration(labelText: '负责人'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('待分配')),
                      ...people.map(
                        (p) => DropdownMenuItem(
                          value: personId(p),
                          child: Text(
                            '${str(p['name'])}${p['kind'] == 'agent' ? ' · Agent' : ''}',
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) => assignee = v?.isEmpty == true ? null : v,
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
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
                      if (title.text.trim().isEmpty) {
                        change(() => error = '请填写任务名称');
                        return;
                      }
                      change(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await state.createTask(
                          title.text.trim(),
                          description: description.text.trim(),
                          assigneeId: assignee,
                          roomId: roomId,
                        );
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (e) {
                        if (dialogContext.mounted) {
                          change(() {
                            error = friendlyError(e);
                            busy = false;
                          });
                        }
                      }
                    },
              child: Text(busy ? '正在创建…' : '创建任务'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    description.dispose();
  }

  static Future<void> document(
    BuildContext context,
    OfficeState state, [
    Json? source,
  ]) async {
    final roomIds = (source?['room_ids'] as List? ?? []).map(str).toList();
    final roomId =
        source?['room_id'] as String? ??
        (roomIds.contains(state.selectedRoomId)
            ? state.selectedRoomId
            : roomIds.firstOrNull) ??
        state.selectedRoomId ??
        await chooseOfficeRoom(context, state);
    if (roomId == null || !context.mounted) return;
    if (source?['id'] != null && source?['content'] == null) {
      source = await state.getDocument(str(source!['id']), roomId: roomId);
      if (!context.mounted) return;
    }
    final draftKey =
        '${state.endpoint}:${personId(state.me ?? {})}:$roomId:${source?['id'] ?? 'new'}';
    final draft = _documentDrafts[draftKey];
    final title = TextEditingController(
      text: str(draft?['title'] ?? source?['title']),
    );
    final content = TextEditingController(
      text: str(draft?['content'] ?? source?['content']),
    );
    String? id = source?['id'];
    int? revision = draft?['revision'] ?? source?['revision'];
    String? error;
    var busy = false, saved = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) => Dialog(
          insetPadding: const EdgeInsets.all(18),
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 850,
              maxHeight: MediaQuery.sizeOf(context).height * .87,
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.description_outlined,
                        color: accentColor,
                        size: 18,
                      ),
                      const SizedBox(width: 9),
                      const Text(
                        '共同文档',
                        style: TextStyle(fontSize: 12, color: mutedColor),
                      ),
                      const Spacer(),
                      Text(
                        revision == null ? '新建文档' : '共同版本 r$revision',
                        style: const TextStyle(fontSize: 11, color: mutedColor),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        tooltip: '关闭文档',
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                  TextField(
                    controller: title,
                    maxLength: 200,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: const InputDecoration(
                      hintText: '给这份文档起个名字',
                      filled: false,
                      counterText: '',
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => saved = false,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 11),
                    child: Text(
                      '人和 Agent 读取同一份内容。保存后，所有会话成员可继续共同编辑。',
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: TextField(
                      controller: content,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontSize: 13, height: 1.9),
                      decoration: const InputDecoration(
                        hintText: '# 共同目标\n\n写下背景、依据和行动计划…',
                        filled: false,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 18),
                      ),
                      onChanged: (_) => saved = false,
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 9,
                    runSpacing: 9,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: content.text),
                          );
                          if (context.mounted) notifyOffice(context, '文档原文已复制');
                        },
                        icon: const Icon(Icons.copy_outlined, size: 15),
                        label: const Text('复制 Markdown'),
                      ),
                      if (error != null && id != null)
                        TextButton(
                          onPressed: () async {
                            try {
                              final latest = await state.getDocument(
                                id!,
                                roomId: roomId,
                              );
                              if (!dialogContext.mounted) return;
                              change(() {
                                revision = latest['revision'];
                                content.text =
                                    '<!-- 你的未合并草稿 -->\n${content.text}\n\n<!-- 共同文档最新版本 r$revision -->\n${str(latest['content'])}';
                                error = '已保留草稿与最新版本。请合并内容、移除分隔说明后保存。';
                              });
                            } catch (e) {
                              change(() => error = friendlyError(e));
                            }
                          },
                          child: const Text('读取最新版本并合并'),
                        ),
                      FilledButton(
                        onPressed: busy
                            ? null
                            : () async {
                                if (title.text.trim().isEmpty ||
                                    content.text.trim().isEmpty) {
                                  change(() => error = '请填写标题与正文');
                                  return;
                                }
                                change(() {
                                  busy = true;
                                  error = null;
                                });
                                try {
                                  final result = await state.saveDocument(
                                    id: id,
                                    title: title.text.trim(),
                                    content: content.text,
                                    baseRevision: revision,
                                    roomId: roomId,
                                  );
                                  if (!dialogContext.mounted) return;
                                  change(() {
                                    id = result['id'];
                                    revision = result['revision'];
                                    busy = false;
                                    saved = true;
                                  });
                                  _documentDrafts.remove(draftKey);
                                  notifyOffice(context, '共同文档已保存');
                                } catch (e) {
                                  if (dialogContext.mounted) {
                                    change(() {
                                      error = friendlyError(e);
                                      busy = false;
                                    });
                                  }
                                }
                              },
                        child: Text(busy ? '正在保存…' : '保存共同文档'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!saved && (title.text.isNotEmpty || content.text.isNotEmpty)) {
      _documentDrafts[draftKey] = {
        'title': title.text,
        'content': content.text,
        'revision': revision,
      };
    }
    title.dispose();
    content.dispose();
  }

  static Future<void> run(
    BuildContext context,
    OfficeState state,
    String id,
  ) async {
    final parentContext = context;
    final future = state.getRun(id);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(18),
        backgroundColor: Colors.white,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 820,
            maxHeight: MediaQuery.sizeOf(context).height * .87,
          ),
          child: FutureBuilder<Json>(
            future: future,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return Padding(
                  padding: const EdgeInsets.all(50),
                  child: snapshot.hasError
                      ? Text(friendlyError(snapshot.error!))
                      : const Center(child: CircularProgressIndicator()),
                );
              }
              final run = snapshot.data!;
              final result = run['result'] is Map
                  ? Map<String, dynamic>.from(run['result'])
                  : <String, dynamic>{};
              final artifact = result['artifact'] is Map
                  ? Map<String, dynamic>.from(result['artifact'])
                  : null;
              final evidence = run['context'] ?? {};
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '工作记录与共同依据',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    Text(
                      '${statusName(run['status'])} · ${clockText(run['created_at'], date: true)}',
                      style: const TextStyle(fontSize: 11, color: mutedColor),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (artifact != null) ...[
                              Text(
                                str(artifact['title']),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 13),
                              SelectableText(
                                str(artifact['content']),
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.85,
                                ),
                              ),
                              const SizedBox(height: 14),
                              FilledButton.icon(
                                onPressed: () async {
                                  try {
                                    final doc = await state.saveArtifact(id);
                                    if (dialogContext.mounted) {
                                      Navigator.pop(dialogContext);
                                      if (parentContext.mounted) {
                                        await document(
                                          parentContext,
                                          state,
                                          doc,
                                        );
                                      }
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      notifyOffice(context, friendlyError(e));
                                    }
                                  }
                                },
                                icon: const Icon(
                                  Icons.note_add_outlined,
                                  size: 17,
                                ),
                                label: const Text('保存为共同文档'),
                              ),
                              const Divider(height: 36),
                            ],
                            if (result['rationale'] != null) ...[
                              const Text(
                                '判断与说明',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 9),
                              SelectableText(
                                str(result['rationale']),
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.8,
                                ),
                              ),
                              const SizedBox(height: 25),
                            ],
                            const Text(
                              '完整依据快照',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '本次读取的讨论、文档版本、任务与省略范围都保留在这里。',
                              style: TextStyle(fontSize: 11, color: mutedColor),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xfff7f8fa),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: SelectableText(
                                const JsonEncoder.withIndent('  ')
                                    .convert(evidence),
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.8,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static Future<String?> editText(
    BuildContext context,
    String value, {
    String title = '编辑消息',
  }) async {
    final controller = TextEditingController(text: value);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 18)),
        content: SizedBox(
          width: 450,
          child: TextField(
            controller: controller,
            minLines: 3,
            maxLines: 10,
            autofocus: true,
            decoration: const InputDecoration(hintText: '消息内容'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  static Future<void> export(BuildContext context, OfficeState state) async {
    try {
      final text = await state.exportRoom();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导出工作记录', style: TextStyle(fontSize: 18)),
          content: SizedBox(
            width: 650,
            height: 420,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontSize: 11, height: 1.8),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) notifyOffice(context, '完整工作记录已复制');
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制 Markdown'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) notifyOffice(context, friendlyError(e));
    }
  }
}
