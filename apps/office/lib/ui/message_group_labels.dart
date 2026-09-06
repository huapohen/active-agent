import 'package:flutter/material.dart';

import '../message_groups.dart';
import '../office_state.dart' hide Json;
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'message_group_widgets.dart';

Future<void> showOfficeMessageLabelEditor(
  BuildContext context,
  OfficeMessageGroups controller, {
  Json? label,
}) => showOfficeMessageGroupDialog(
  context,
  controller,
  builder: (_) => _MessageLabelEditor(controller: controller, label: label),
);
Future<void> showOfficeMessageLabelRooms(
  BuildContext context,
  OfficeMessageGroups controller,
  Json label,
) => showOfficeMessageGroupDialog(
  context,
  controller,
  builder: (_) => _MessageLabelRooms(controller: controller, label: label),
);
Future<void> showOfficeRoomGrouping(
  BuildContext context,
  OfficeMessageGroups controller,
  Json room,
) => showOfficeMessageGroupDialog(
  context,
  controller,
  builder: (_) => _RoomGrouping(controller: controller, room: room),
);

class _MessageLabelEditor extends StatefulWidget {
  const _MessageLabelEditor({required this.controller, this.label});
  final OfficeMessageGroups controller;
  final Json? label;
  @override
  State<_MessageLabelEditor> createState() => _MessageLabelEditorState();
}

class _MessageLabelEditorState extends State<_MessageLabelEditor> {
  late final _name = TextEditingController(text: str(widget.label?['name']));
  late final _rule = TextEditingController(
    text: str(widget.label?['name_contains']),
  );
  late final String _identity;
  final _client = OfficeState.newClientId();
  late int _revision;
  bool _busy = false, _conflict = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _identity = widget.controller.identityKey;
    _revision = widget.controller.revision;
  }

  @override
  void dispose() {
    _name.dispose();
    _rule.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请输入标签名称');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.controller.assertIdentity(_identity);
      final name = _name.text.trim(), rule = _rule.text.trim();
      if (widget.label == null) {
        final result = await widget.controller.createLabel(
          baseRevision: _revision,
          clientId: _client,
          name: name,
          nameContains: rule.isEmpty ? null : rule,
        );
        if (result['created_group_id'] is String) {
          widget.controller.select(result['created_group_id']);
        }
      } else {
        await widget.controller.updateLabel(str(widget.label!['id']), {
          'name': name,
          'name_contains': rule.isEmpty ? null : rule,
        }, baseRevision: _revision);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = friendlyError(error);
          _conflict = error is OfficeException && error.status == 409;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read() async {
    setState(() => _busy = true);
    try {
      widget.controller.assertIdentity(_identity);
      await widget.controller.readLatest();
      if (mounted) {
        setState(() {
          _revision = widget.controller.revision;
          _conflict = false;
          _error = '已读取新版本并保留输入，请核对后重新保存。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.label == null ? '新建标签' : '编辑标签'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              autofocus: true,
              maxLength: 40,
              decoration: const InputDecoration(labelText: '标签名称'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _rule,
              enabled: !_busy,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '会话名称包含（可选）',
                helperText: '匹配的会话自动加入；清空可移除自动规则',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '标签只整理你有权查看的会话。人类、Agent 私聊与混合群均可加入，不改变成员权限。',
              style: TextStyle(fontSize: 11, color: mutedColor, height: 1.7),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ),
            if (_conflict)
              TextButton(
                onPressed: _busy ? null : _read,
                child: const Text('读取最新版本并保留输入'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? '保存中…' : '保存标签'),
      ),
    ],
  );
}

Future<void> deleteOfficeMessageLabel(
  BuildContext context,
  OfficeMessageGroups controller,
  Json label,
) async {
  final identity = controller.identityKey;
  var revision = controller.revision;
  var busy = false, conflict = false;
  String? error;
  await showOfficeMessageGroupDialog(
    context,
    controller,
    builder: (context) => StatefulBuilder(
      builder: (context, change) => AlertDialog(
        title: Text('删除标签“${str(label['name'])}”？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('只移除你的标签与归组关系，会话和消息会保留。'),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            if (conflict)
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        change(() => busy = true);
                        try {
                          controller.assertIdentity(identity);
                          await controller.readLatest();
                          if (context.mounted) {
                            change(() {
                              revision = controller.revision;
                              conflict = false;
                              error = '已读取最新分组，请重新确认删除。';
                            });
                          }
                        } catch (e) {
                          if (context.mounted) {
                            change(() => error = friendlyError(e));
                          }
                        } finally {
                          if (context.mounted) change(() => busy = false);
                        }
                      },
                child: const Text('读取最新分组'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    change(() => busy = true);
                    try {
                      controller.assertIdentity(identity);
                      await controller.deleteLabel(
                        str(label['id']),
                        baseRevision: revision,
                      );
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      if (context.mounted) {
                        change(() {
                          error = friendlyError(e);
                          conflict = e is OfficeException && e.status == 409;
                        });
                      }
                    } finally {
                      if (context.mounted) change(() => busy = false);
                    }
                  },
            child: Text(busy ? '删除中…' : '删除标签'),
          ),
        ],
      ),
    ),
  );
}

class _MessageLabelRooms extends StatefulWidget {
  const _MessageLabelRooms({required this.controller, required this.label});
  final OfficeMessageGroups controller;
  final Json label;
  @override
  State<_MessageLabelRooms> createState() => _MessageLabelRoomsState();
}

class _MessageLabelRoomsState extends State<_MessageLabelRooms> {
  late final String _identity;
  late int _revision;
  late Set<String> _existing = Set<String>.from(widget.label['room_ids'] ?? []);
  @override
  void initState() {
    super.initState();
    _identity = widget.controller.identityKey;
    _revision = widget.controller.revision;
  }

  final Set<String> _selected = {};
  String _query = '';
  String? _error;
  bool _busy = false, _conflict = false;
  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.controller.assertIdentity(_identity);
      await widget.controller.updateLabel(str(widget.label['id']), {
        'add_room_ids': _selected.toList(),
      }, baseRevision: _revision);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = friendlyError(error);
          _conflict = error is OfficeException && error.status == 409;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read() async {
    setState(() => _busy = true);
    try {
      widget.controller.assertIdentity(_identity);
      await widget.controller.readLatest();
      final latest = widget.controller.group(str(widget.label['id']));
      if (latest == null) throw OfficeException(404, '该标签已被删除');
      if (mounted) {
        setState(() {
          _revision = widget.controller.revision;
          _existing = Set<String>.from(latest['room_ids'] ?? []);
          _selected.removeWhere(_existing.contains);
          _conflict = false;
          _error = '已读取新版本并保留尚未加入的选择，请核对后再添加。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rooms = widget.controller.state.rooms
        .where(
          (room) =>
              str(room['name']).toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final list = ListView(
      children: [
        for (final room in rooms)
          CheckboxListTile(
            value:
                _existing.contains(room['id']) ||
                _selected.contains(room['id']),
            onChanged: _busy || _existing.contains(room['id'])
                ? null
                : (value) => setState(
                    () => value == true
                        ? _selected.add(str(room['id']))
                        : _selected.remove(room['id']),
                  ),
            title: Text(
              str(room['name']),
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: _existing.contains(room['id'])
                ? const Text('已在标签中', style: TextStyle(fontSize: 10))
                : null,
            secondary: Icon(
              room['kind'] == 'direct'
                  ? Icons.person_outline
                  : Icons.group_outlined,
              size: 20,
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
      ],
    );
    return AlertDialog(
      title: Text('添加会话 · ${str(widget.label['name'])}'),
      content: SizedBox(
        width: 650,
        height: MediaQuery.sizeOf(context).height * .55,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(hintText: '搜索会话'),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '已选：${_selected.length} 个会话',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Expanded(
              child: wide
                  ? Row(
                      children: [
                        Expanded(child: list),
                        const VerticalDivider(),
                        SizedBox(
                          width: 210,
                          child: ListView(
                            children: [
                              for (final room
                                  in widget.controller.state.rooms.where(
                                    (room) => _selected.contains(room['id']),
                                  ))
                                ListTile(
                                  dense: true,
                                  title: Text(
                                    str(room['name']),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  trailing: IconButton(
                                    tooltip: '移除${room['name']}',
                                    onPressed: _busy
                                        ? null
                                        : () => setState(
                                            () => _selected.remove(room['id']),
                                          ),
                                    icon: const Icon(Icons.close, size: 16),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : list,
            ),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(fontSize: 11, color: Colors.red),
              ),
            if (_conflict)
              TextButton(
                onPressed: _busy ? null : _read,
                child: const Text('读取最新分组并保留选择'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || _selected.isEmpty ? null : _save,
          child: Text(_busy ? '添加中…' : '添加会话'),
        ),
      ],
    );
  }
}

class _RoomGrouping extends StatefulWidget {
  const _RoomGrouping({required this.controller, required this.room});
  final OfficeMessageGroups controller;
  final Json room;
  @override
  State<_RoomGrouping> createState() => _RoomGroupingState();
}

class _RoomGroupingState extends State<_RoomGrouping> {
  late final String _identity;
  int _revision = 0;
  Set<String> _manual = {}, _matched = {};
  bool _marked = false,
      _completed = false,
      _busy = true,
      _loaded = false,
      _conflict = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _identity = widget.controller.identityKey;
    _read();
  }

  Future<void> _read({bool preserve = false}) async {
    setState(() => _busy = true);
    try {
      widget.controller.assertIdentity(_identity);
      final snapshot = await widget.controller.readLatest();
      final baseRevision = (snapshot['revision'] as num).toInt();
      final detail = await widget.controller.roomDetail(str(widget.room['id']));
      final grouping = (detail['room'] as Map?)?['message_grouping'] as Map?;
      if (grouping == null) throw OfficeException(502, '会话归组响应不完整');
      if (mounted) {
        setState(() {
          _revision = baseRevision;
          _matched = Set<String>.from(grouping['matched_group_ids'] ?? []);
          if (!preserve) {
            _manual = Set<String>.from(grouping['manual_group_ids'] ?? []);
            _marked = grouping['marked'] == true;
            _completed = grouping['completed'] == true;
          } else {
            final ids = widget.controller.labels
                .map((label) => label['id'])
                .toSet();
            _manual.removeWhere((id) => !ids.contains(id));
          }
          _loaded = true;
          _conflict = false;
          _error = preserve ? '已读取最新归组并保留你的选择，请核对后重新保存。' : null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.controller.assertIdentity(_identity);
      await widget.controller.updateRoom(str(widget.room['id']), {
        'group_ids': _manual.toList(),
        'marked': _marked,
        'completed': _completed,
      }, baseRevision: _revision);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = friendlyError(error);
          _conflict = error is OfficeException && error.status == 409;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('整理会话 · ${str(widget.room['name'])}'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_loaded) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('标记', style: TextStyle(fontSize: 13)),
                value: _marked,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _marked = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('已完成', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '仅整理个人会话，不关闭群聊或更改任务状态。',
                  style: TextStyle(fontSize: 11),
                ),
                value: _completed,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _completed = value),
              ),
              const Divider(),
              const Text(
                '标签',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              if (widget.controller.labels.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    '先从消息分组中新建标签。',
                    style: TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ),
              for (final label in widget.controller.labels)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    str(label['name']),
                    style: const TextStyle(fontSize: 12),
                  ),
                  value:
                      _manual.contains(label['id']) ||
                      _matched.contains(label['id']),
                  subtitle: _matched.contains(label['id'])
                      ? const Text(
                          '由名称规则自动加入；编辑规则后才能移出。',
                          style: TextStyle(fontSize: 10),
                        )
                      : null,
                  onChanged: _busy || _matched.contains(label['id'])
                      ? null
                      : (value) => setState(
                          () => value == true
                              ? _manual.add(str(label['id']))
                              : _manual.remove(label['id']),
                        ),
                ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ),
            if (!_loaded || _conflict)
              TextButton(
                onPressed: _busy ? null : () => _read(preserve: _loaded),
                child: Text(_loaded ? '读取最新归组并保留选择' : '重新读取会话'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy || !_loaded ? null : _save,
        child: const Text('保存归组'),
      ),
    ],
  );
}
