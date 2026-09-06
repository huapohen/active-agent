import 'package:flutter/material.dart';

import '../message_groups.dart';
import '../office_state.dart' show OfficeException;
import 'message_group_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

Future<void> showOfficeMessageGroupEditor(
  BuildContext context,
  OfficeMessageGroups controller,
) => showOfficeMessageGroupDialog(
  context,
  controller,
  builder: (_) => OfficeMessageGroupEditor(controller: controller),
);

class OfficeMessageGroupEditor extends StatefulWidget {
  const OfficeMessageGroupEditor({super.key, required this.controller});
  final OfficeMessageGroups controller;
  @override
  State<OfficeMessageGroupEditor> createState() =>
      _OfficeMessageGroupEditorState();
}

class _OfficeMessageGroupEditorState extends State<OfficeMessageGroupEditor> {
  late final String _identity;
  late int _revision;
  late List<String> _order;
  late Set<String> _hidden;
  late List<String> _shortcuts;
  late List<Json> _groups;
  @override
  void initState() {
    super.initState();
    _identity = widget.controller.identityKey;
    _revision = widget.controller.revision;
    _order = widget.controller.order;
    _hidden = Set<String>.from(widget.controller.snapshot['hidden_ids'] ?? []);
    _shortcuts = widget.controller.shortcuts;
    _groups = widget.controller.groups;
  }

  Json? _latest;
  String? _error;
  bool _busy = false, _conflict = false;
  Json item(String id) => _groups.firstWhere((group) => group['id'] == id);

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.controller.assertIdentity(_identity);
      await widget.controller.saveLayout(
        baseRevision: _revision,
        order: _order,
        hiddenIds: _hidden.toList(),
        shortcutIds: _shortcuts,
      );
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

  Future<void> _readLatest() async {
    setState(() => _busy = true);
    try {
      widget.controller.assertIdentity(_identity);
      final latest = await widget.controller.readLatest();
      if (mounted) setState(() => _latest = latest);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _adopt() => setState(() {
    final current = List<String>.from(_latest!['order']);
    _groups = maps(_latest!['groups']);
    _order = [
      ..._order.where(current.contains),
      ...current.where((id) => !_order.contains(id)),
    ];
    _hidden = _hidden.where(current.contains).toSet()..remove('messages');
    _shortcuts = [
      'messages',
      ..._shortcuts.where((id) => id != 'messages' && current.contains(id)),
    ];
    _revision = (_latest!['revision'] as num).toInt();
    _latest = null;
    _conflict = false;
    _error = null;
  });

  void _move(List<String> section, int old, int next) {
    if (section[old] == 'messages' ||
        (section.contains('messages') && next == 0)) {
      return;
    }
    final sorted = [...section];
    sorted.insert(next, sorted.removeAt(old));
    var cursor = 0;
    setState(
      () => _order = [
        for (final id in _order) section.contains(id) ? sorted[cursor++] : id,
      ],
    );
  }

  Widget _section(String title, List<String> ids, {bool hidden = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
            child: Text(
              title,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (old, next) => _move(ids, old, next),
            children: [
              for (var index = 0; index < ids.length; index++)
                Material(
                  key: ValueKey(ids[index]),
                  color: Colors.white,
                  child: ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 10),
                    leading: Icon(
                      officeMessageGroupIcon(item(ids[index])),
                      size: 18,
                    ),
                    minLeadingWidth: 18,
                    title: Text(
                      str(item(ids[index])['name']),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ids[index] != 'messages' && !hidden) ...[
                          _smallButton(
                            '上移${item(ids[index])['name']}',
                            Icons.arrow_upward,
                            !_busy && index > (ids.contains('messages') ? 1 : 0)
                                ? () => _move(ids, index, index - 1)
                                : null,
                          ),
                          _smallButton(
                            '下移${item(ids[index])['name']}',
                            Icons.arrow_downward,
                            !_busy && index < ids.length - 1
                                ? () => _move(ids, index, index + 1)
                                : null,
                          ),
                        ],
                        _smallButton(
                          '${hidden ? '展示' : '隐藏'}${item(ids[index])['name']}',
                          hidden
                              ? Icons.add_circle_outline
                              : Icons.remove_circle_outline,
                          _busy || ids[index] == 'messages'
                              ? null
                              : () => setState(
                                  () => hidden
                                      ? _hidden.remove(ids[index])
                                      : _hidden.add(ids[index]),
                                ),
                        ),
                        if (ids[index] != 'messages' && !hidden)
                          ReorderableDragStartListener(
                            index: index,
                            enabled: !_busy,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: Icon(
                                Icons.drag_handle,
                                size: 18,
                                color: mutedColor,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      );

  Widget _smallButton(String tooltip, IconData icon, VoidCallback? action) =>
      IconButton(
        tooltip: tooltip,
        onPressed: action,
        icon: Icon(icon, size: 16),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 36),
      );

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 760;
    final body = Scaffold(
      backgroundColor: const Color(0xfff6f7fa),
      appBar: AppBar(
        title: const Text('编辑分组'),
        leading: TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? '保存中…' : '保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '常用分组',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final id in _shortcuts)
                InputChip(
                  label: Text(str(item(id)['name'])),
                  onDeleted: id == 'messages' || _busy
                      ? null
                      : () => setState(() => _shortcuts.remove(id)),
                ),
              PopupMenuButton<String>(
                tooltip: '添加常用分组',
                enabled: !_busy && _shortcuts.length < 8,
                onSelected: (id) => setState(() => _shortcuts.add(id)),
                itemBuilder: (_) => _groups
                    .where(
                      (group) =>
                          !_shortcuts.contains(group['id']) &&
                          group['available'] != false,
                    )
                    .map(
                      (group) => PopupMenuItem(
                        value: str(group['id']),
                        child: Text(str(group['name'])),
                      ),
                    )
                    .toList(),
                icon: const Icon(Icons.add_circle_outline, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '最多8个常用分组，消息固定。侧栏显示与常用分组分别设置。',
            style: TextStyle(fontSize: 11, color: mutedColor),
          ),
          _section(
            '侧栏分组',
            _order
                .where(
                  (id) =>
                      item(id)['type'] == 'builtin' && !_hidden.contains(id),
                )
                .toList(),
          ),
          _section(
            '标签顺序',
            _order
                .where(
                  (id) => item(id)['type'] == 'label' && !_hidden.contains(id),
                )
                .toList(),
          ),
          _section('隐藏', _order.where(_hidden.contains).toList(), hidden: true),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ),
          if (_conflict)
            TextButton(
              onPressed: _busy ? null : _readLatest,
              child: const Text('读取最新分组'),
            ),
          if (_latest != null) ...[
            const Text(
              '服务器分组已更新。保留仍存在的本地排序与选择，新建分组追加到末尾。',
              style: TextStyle(fontSize: 11, height: 1.7),
            ),
            TextButton(
              onPressed: _busy ? null : _adopt,
              child: const Text('保留我的编辑并采用新版本'),
            ),
          ],
        ],
      ),
    );
    return mobile
        ? Dialog.fullscreen(child: body)
        : Dialog(
            child: SizedBox(
              width: 620,
              height: MediaQuery.sizeOf(context).height * .85,
              child: body,
            ),
          );
  }
}
