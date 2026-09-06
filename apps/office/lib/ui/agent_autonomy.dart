import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'agent_action_plan.dart';
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'companion_identity.dart';

Future<void> showAgentAutonomy(
  BuildContext context,
  OfficeState state,
  Json member, {
  required String roomId,
  required bool canEdit,
  int? roomRevision,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _AgentAutonomy(
    state: state,
    member: member,
    roomId: roomId,
    canEdit: canEdit,
    roomRevision: roomRevision,
  ),
);

class _AgentAutonomy extends StatefulWidget {
  const _AgentAutonomy({
    required this.state,
    required this.member,
    required this.roomId,
    required this.canEdit,
    this.roomRevision,
  });
  final OfficeState state;
  final Json member;
  final String roomId;
  final bool canEdit;
  final int? roomRevision;
  @override
  State<_AgentAutonomy> createState() => _AgentAutonomyState();
}

class _AgentAutonomyState extends State<_AgentAutonomy> {
  late final Json _initial = widget.member['autonomy'] is Map
      ? Json.from(widget.member['autonomy'])
      : {};
  late bool _enabled = _initial['enabled'] == true;
  late String _mode = str(widget.member['mode'], 'mentions');
  late int _steps = (_initial['max_steps'] as num?)?.toInt() ?? 1;
  late final _interval = TextEditingController(
    text: str(_initial['review_interval_seconds']),
  );
  late final _operations = (_initial['allowed_operations'] as List? ?? [])
      .map(str)
      .toSet();
  late final _available =
      (widget.member['autonomy_available_operations'] as List? ??
              [
                ...agentActionNames.keys.where(
                  (id) => !id.endsWith('_document'),
                ),
                ..._operations,
              ])
          .map(str)
          .toSet();
  late int? _revision =
      widget.roomRevision ??
      ((widget.state.detail?['room'] as Map?)?['revision'] as num?)?.toInt();
  String? _error;
  Json? _latest;
  bool _busy = false;
  bool get editable =>
      widget.canEdit && _initial.isNotEmpty && _revision != null;

  Future<void> _setMode(String mode) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.state.configureAgentParticipation(
        widget.roomId,
        personId(widget.member),
        mode: mode,
        baseRevision: _revision!,
      );
      if (mounted) {
        setState(() {
          _mode = str((result['member'] as Map?)?['mode'], mode);
          _revision = (result['room_revision'] as num?)?.toInt() ?? _revision;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _interval.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final seconds = int.tryParse(_interval.text.trim());
    if (seconds == null || seconds < 60 || seconds > 86400) {
      setState(() => _error = '主动复核间隔须为 60 至 86400 秒');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.configureAgentAutonomy(
        widget.roomId,
        personId(widget.member),
        baseRevision: _revision!,
        autonomy: {
          'enabled': _enabled,
          'max_steps': _steps,
          'allowed_operations': _operations.toList()..sort(),
          'review_interval_seconds': seconds,
        },
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readLatest() async {
    setState(() => _busy = true);
    try {
      final result = await widget.state.officeRequest(
        '/rooms/${Uri.encodeComponent(widget.roomId)}',
      );
      final member = maps(result['members'])
          .where((m) => personId(m) == personId(widget.member))
          .firstOrNull;
      if (member == null || member['autonomy'] is! Map) {
        throw OfficeException(404, '该成员或主动性配置已不存在');
      }
      if (mounted) {
        setState(() {
          _revision = ((result['room'] as Map?)?['revision'] as num?)?.toInt();
          _mode = str(member['mode'], _mode);
          _latest = Json.from(member['autonomy']);
          _error = '已读取最新版本并保留你的编辑。请核对最新策略，再保存。';
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
    title: Text('${str(widget.member['name'])} · 人格与参与'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '工作会话：${str(widget.state.rooms.where((room) => room['id'] == widget.roomId).firstOrNull?['name'], widget.roomId)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              '每位 Agent 都可主动参与。这里的设置只作用于当前工作会话；自主执行动作另外配置，并继续遵守成员权限。',
              style: TextStyle(fontSize: 11, height: 1.8, color: mutedColor),
            ),
            if (_initial.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: Text('当前服务尚未提供该成员的主动性策略。请刷新工作会话后重试。'),
              ),
            if (!widget.canEdit)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  '你可以查看策略；该 Agent 本人和会话所有者可以修改。',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('主动参与', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                _mode == 'paused'
                    ? '当前已暂停；恢复参与后可调整。'
                    : _mode == 'active'
                    ? '主动关注共同上下文，决定何时推进工作。'
                    : '被提及或收到直接任务时参与。',
                style: const TextStyle(fontSize: 11, height: 1.6),
              ),
              value: _mode == 'active',
              onChanged:
                  widget.canEdit &&
                      _revision != null &&
                      !_busy &&
                      _mode != 'paused'
                  ? (value) => _setMode(value ? 'active' : 'mentions')
                  : null,
            ),
            TextButton.icon(
              onPressed: widget.canEdit && _revision != null && !_busy
                  ? () => _setMode(_mode == 'paused' ? 'mentions' : 'paused')
                  : null,
              icon: Icon(
                _mode == 'paused' ? Icons.play_arrow : Icons.pause,
                size: 16,
              ),
              label: Text(_mode == 'paused' ? '恢复参与（被提及时）' : '暂停参与'),
            ),
            const Text(
              '参与方式切换立即保存；下方动作策略点击保存后生效。',
              style: TextStyle(fontSize: 11, height: 1.7, color: mutedColor),
            ),
            const Divider(height: 26),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许主动执行', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                '独立控制工具动作与定时复核。关闭后仍可按参与方式讨论。',
                style: TextStyle(fontSize: 11, height: 1.6),
              ),
              value: _enabled,
              onChanged: editable && !_busy
                  ? (value) => setState(() => _enabled = value)
                  : null,
            ),
            DropdownButtonFormField<int>(
              initialValue: [1, 2, 3, 4].contains(_steps) ? _steps : 1,
              decoration: const InputDecoration(labelText: '每轮最多执行动作数'),
              items: [1, 2, 3, 4]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n 项')))
                  .toList(),
              onChanged: editable && !_busy
                  ? (value) => setState(() => _steps = value ?? 1)
                  : null,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _interval,
              enabled: editable && !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '主动复核间隔（秒）',
                helperText: '60–86400 秒；复核自己的未完成任务和临近日程',
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '允许执行的动作',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            ...agentActionNames.entries
                .where((entry) => _available.contains(entry.key))
                .map(
                  (entry) => CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      entry.value,
                      style: const TextStyle(fontSize: 12),
                    ),
                    value: _operations.contains(entry.key),
                    onChanged: editable && !_busy
                        ? (checked) => setState(
                            () => checked == true
                                ? _operations.add(entry.key)
                                : _operations.remove(entry.key),
                          )
                        : null,
                  ),
                ),
            CompanionCapabilities(person: widget.member),
            if (_latest != null)
              BusinessCard(
                child: Text(
                  '最新已保存策略：${_latest!['enabled'] == true ? '允许主动执行' : '暂停主动执行'}；每轮 ${_latest!['max_steps']} 项；间隔 ${_latest!['review_interval_seconds']} 秒；动作：${(_latest!['allowed_operations'] as List? ?? []).map((id) => agentActionNames[id] ?? str(id)).join('、')}',
                  style: const TextStyle(fontSize: 11, height: 1.8),
                ),
              ),
            BusinessError(_error),
            if (_error != null)
              TextButton(
                onPressed: _busy ? null : _readLatest,
                child: const Text('读取最新策略并保留编辑'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      if (widget.canEdit)
        FilledButton(
          onPressed: editable && !_busy ? _save : null,
          child: Text(_busy ? '正在保存…' : '保存主动性策略'),
        ),
    ],
  );
}
