import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeNavigationItem {
  const OfficeNavigationItem(this.id, this.label, this.icon, this.route);
  final String id, label;
  final IconData icon;
  final int route;
}

const officeNavigationItems = [
  OfficeNavigationItem('messages', '消息', Icons.chat_bubble_outline, 0),
  OfficeNavigationItem('agents', 'Agent', Icons.auto_awesome_outlined, 1),
  OfficeNavigationItem('contacts', '通讯录', Icons.contacts_outlined, 2),
  OfficeNavigationItem('docs', '云文档', Icons.folder_outlined, 3),
  OfficeNavigationItem('tasks', '任务', Icons.task_alt, 4),
  OfficeNavigationItem('workbench', '工作台', Icons.grid_view_rounded, 5),
  OfficeNavigationItem('meetings', '视频会议', Icons.videocam_outlined, 6),
  OfficeNavigationItem('calendar', '日历', Icons.calendar_month_outlined, 7),
  OfficeNavigationItem('mail', '邮箱', Icons.mail_outline, 8),
  OfficeNavigationItem('attendance', '考勤', Icons.fingerprint, 9),
  OfficeNavigationItem('approvals', '审批', Icons.fact_check_outlined, 10),
  OfficeNavigationItem('minutes', '人机妙记', Icons.graphic_eq, 14),
  OfficeNavigationItem('enterprise', '企业管理', Icons.apartment_outlined, 13),
];
const defaultOfficeMobileNavigation = [
  'messages',
  'agents',
  'docs',
  'workbench',
];

List<OfficeNavigationItem> officeMobileNavigation(
  OfficeState state, [
  List<dynamic>? configured,
]) {
  final raw =
      configured ??
      (state.settings['mobile_nav'] as List? ?? defaultOfficeMobileNavigation);
  final ids = raw.map(str).toSet();
  final selected = <OfficeNavigationItem>[];
  for (final id in ids) {
    if (id == 'enterprise' && !state.canManageEnterprise) continue;
    final entry = officeNavigationItems
        .where((item) => item.id == id)
        .firstOrNull;
    if (entry != null && selected.length < 4) selected.add(entry);
  }
  return selected.isEmpty
      ? officeNavigationItems
            .where((item) => defaultOfficeMobileNavigation.contains(item.id))
            .toList()
      : selected;
}

Future<void> showOfficeNavigationEditor(
  BuildContext context,
  OfficeState state,
) => showDialog<void>(
  context: context,
  builder: (_) => OfficeNavigationEditor(state: state),
);

class OfficeNavigationEditor extends StatefulWidget {
  const OfficeNavigationEditor({super.key, required this.state});
  final OfficeState state;
  @override
  State<OfficeNavigationEditor> createState() => _OfficeNavigationEditorState();
}

class _OfficeNavigationEditorState extends State<OfficeNavigationEditor> {
  late final OfficeState _owner;
  late final (int, String, String) _identity;
  late List<String> _selected;
  late int _revision;
  bool _busy = false, _conflict = false, _expired = false;
  String? _error;
  Json? _latest;

  (int, String, String) get _currentIdentity => (
    widget.state.identityGeneration,
    widget.state.endpoint,
    personId(widget.state.me ?? {}),
  );
  bool get _current =>
      !_expired &&
      identical(_owner, widget.state) &&
      widget.state.me != null &&
      _identity == _currentIdentity;

  @override
  void initState() {
    super.initState();
    _owner = widget.state;
    _identity = _currentIdentity;
    _selected = officeMobileNavigation(_owner).map((item) => item.id).toList();
    _revision = (_owner.settings['revision'] as num?)?.toInt() ?? 1;
    _owner.addListener(_identityChanged);
  }

  void _identityChanged() {
    if (!_current) {
      _expired = true;
      _latest = null;
      _selected.clear();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _owner.removeListener(_identityChanged);
    super.dispose();
  }

  void _move(int oldIndex, int newIndex) {
    if (!_current || _busy) return;
    setState(() => _selected.insert(newIndex, _selected.removeAt(oldIndex)));
  }

  Future<void> _save() async {
    if (!_current || !widget.state.connected || _busy || _conflict) return;
    setState(() {
      _busy = true;
      _error = null;
      _conflict = false;
    });
    try {
      await widget.state.saveSettings({
        'mobile_nav': [..._selected],
      }, baseRevision: _revision);
      if (mounted && _current) Navigator.pop(context);
    } catch (error) {
      if (mounted && _current) {
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
    if (!_current || !widget.state.connected || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.state.officeRequest('/settings');
      if (mounted && _current) {
        setState(() => _latest = Json.from(result['settings']));
      }
    } catch (error) {
      if (mounted && _current) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _adoptRevision({required bool useRemote}) {
    if (!_current || _latest == null || _busy) return;
    setState(() {
      if (useRemote) {
        _selected = officeMobileNavigation(
          widget.state,
          _latest!['mobile_nav'] as List?,
        ).map((item) => item.id).toList();
      }
      _revision = (_latest!['revision'] as num).toInt();
      _latest = null;
      _conflict = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return AlertDialog(
        title: const Text('底栏编辑已锁定'),
        content: const Text('工作身份已变化，请关闭后重新打开底栏编辑。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    final body = Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('编辑底栏'),
        leading: IconButton(
          tooltip: '取消底栏编辑',
          onPressed: _busy ? null : () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        actions: [
          TextButton(
            onPressed: _busy || _conflict || !widget.state.connected
                ? null
                : _save,
            child: Text(_busy ? '保存中…' : '保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '把最常用的办公功能放在手边',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            '已选 ${_selected.length}/4 · 拖动或使用箭头排序，至少保留一项。“更多”固定在最右侧。',
            style: const TextStyle(
              fontSize: 12,
              color: mutedColor,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 16),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _selected.length,
            onReorderItem: _busy ? (_, _) {} : _move,
            itemBuilder: (context, index) {
              final item = officeNavigationItems.firstWhere(
                (item) => item.id == _selected[index],
              );
              return Material(
                key: ValueKey(item.id),
                color: const Color(0xfff4f6fa),
                child: ListTile(
                  contentPadding: const EdgeInsets.only(left: 8),
                  leading: ReorderableDragStartListener(
                    index: index,
                    enabled: !_busy,
                    child: const Icon(Icons.drag_handle, size: 20),
                  ),
                  minLeadingWidth: 20,
                  title: Text(item.label, style: const TextStyle(fontSize: 13)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '上移${item.label}',
                        onPressed: _busy || index == 0
                            ? null
                            : () => _move(index, index - 1),
                        icon: const Icon(Icons.arrow_upward, size: 16),
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        tooltip: '下移${item.label}',
                        onPressed: _busy || index == _selected.length - 1
                            ? null
                            : () => _move(index, index + 1),
                        icon: const Icon(Icons.arrow_downward, size: 16),
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        tooltip: '移除${item.label}',
                        onPressed: _busy || _selected.length == 1
                            ? null
                            : () => setState(() => _selected.removeAt(index)),
                        icon: const Icon(Icons.remove_circle_outline, size: 18),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          const Text('添加功能', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in officeNavigationItems)
                if (!_selected.contains(item.id) &&
                    (item.id != 'enterprise' ||
                        widget.state.canManageEnterprise))
                  ActionChip(
                    label: Text(item.label),
                    avatar: Icon(item.icon, size: 17),
                    onPressed: _busy || _selected.length == 4
                        ? null
                        : () => setState(() => _selected.add(item.id)),
                  ),
            ],
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(
                    () => _selected = [...defaultOfficeMobileNavigation],
                  ),
            child: const Text('恢复默认底栏'),
          ),
          if (_error != null)
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          if (_conflict && _latest == null) ...[
            const Text(
              '设置已在其他客户端修改。你的选择与排序已保留。',
              style: TextStyle(fontSize: 12),
            ),
            TextButton(
              onPressed: _busy || !widget.state.connected ? null : _readLatest,
              child: const Text('读取最新设置'),
            ),
          ],
          if (_latest != null) ...[
            Text(
              '服务器底栏：${officeMobileNavigation(widget.state, _latest!['mobile_nav'] as List?).map((item) => item.label).join(' / ')}',
              style: const TextStyle(fontSize: 12),
            ),
            TextButton(
              onPressed: _busy ? null : () => _adoptRevision(useRemote: true),
              child: const Text('使用服务器底栏'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _adoptRevision(useRemote: false),
              child: const Text('保留我的排序继续编辑'),
            ),
          ],
        ],
      ),
    );
    return MediaQuery.sizeOf(context).width < 600
        ? Dialog.fullscreen(child: body)
        : Dialog(child: SizedBox(width: 580, height: 670, child: body));
  }
}
