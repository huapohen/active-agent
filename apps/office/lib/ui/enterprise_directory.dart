import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../enterprise_state.dart';
import 'business_widgets.dart';
import 'enterprise.dart' show enterpriseRole, enterpriseStatus;
import 'office_dialogs.dart';
import 'office_theme.dart';

String enterpriseDepartmentPath(List<Json> departments, String? id) {
  final found = {
    for (final department in departments) str(department['id']): department,
  };
  final visited = <String>{}, names = <String>[];
  while (id != null && visited.add(id)) {
    final department = found[id];
    if (department == null) break;
    names.insert(0, str(department['name']));
    id = department['parent_id'] as String?;
  }
  return names.isEmpty ? '未分配部门' : names.join(' / ');
}

/// Counts and selection are direct department membership, never invented
/// descendant totals. Searching keeps ancestors so matching nodes keep context.
class EnterpriseDepartmentBrowser extends StatefulWidget {
  const EnterpriseDepartmentBrowser({
    super.key,
    required this.departments,
    required this.onSelected,
    this.selectedId,
    this.showAllMembers = true,
    this.actions,
    this.compact = false,
  });
  final List<Json> departments;
  final ValueChanged<String?> onSelected;
  final String? selectedId;
  final bool showAllMembers, compact;
  final Widget Function(Json)? actions;
  @override
  State<EnterpriseDepartmentBrowser> createState() =>
      _EnterpriseDepartmentBrowserState();
}

class _EnterpriseDepartmentBrowserState
    extends State<EnterpriseDepartmentBrowser> {
  final _collapsed = <String>{};
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final byId = {
      for (final department in widget.departments)
        str(department['id']): department,
    };
    final included = <String>{};
    for (final department in widget.departments) {
      if (_query.isNotEmpty &&
          !str(department['name'])
              .toLowerCase()
              .contains(_query.toLowerCase())) {
        continue;
      }
      String? id = str(department['id']);
      final seen = <String>{};
      while (id != null && seen.add(id)) {
        included.add(id);
        id = byId[id]?['parent_id'] as String?;
      }
    }
    final rows = <({Json department, int depth})>[], visited = <String>{};
    void visit(Json department, int depth) {
      final id = str(department['id']);
      if (!included.contains(id) || !visited.add(id)) return;
      rows.add((department: department, depth: depth));
      if (_query.isEmpty && _collapsed.contains(id)) return;
      for (final child in widget.departments.where(
        (value) => value['parent_id'] == id,
      )) {
        visit(child, depth + 1);
      }
    }

    for (final department in widget.departments.where(
      (value) =>
          value['parent_id'] == null || !byId.containsKey(value['parent_id']),
    )) {
      visit(department, 0);
    }
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(widget.compact ? 10 : 18),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索部门名称',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              if (widget.showAllMembers)
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.apartment_outlined, size: 18),
                    title: const Text('全部成员', style: TextStyle(fontSize: 12)),
                    selected: widget.selectedId == null,
                    onTap: () => widget.onSelected(null),
                  ),
                ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    '没有匹配的部门',
                    style: TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ),
              for (final row in rows)
                Builder(
                  builder: (context) {
                    final department = row.department,
                        id = str(department['id']);
                    final children = widget.departments.any(
                      (value) => value['parent_id'] == id,
                    );
                    final expanded =
                        _query.isNotEmpty || !_collapsed.contains(id);
                    return Material(
                      key: ValueKey('department-node-$id'),
                      color: widget.selectedId == id
                          ? selectedColor
                          : Colors.transparent,
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: (row.depth * 14).clamp(0, 84).toDouble(),
                          right: 6,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: children
                                  ? IconButton(
                                      tooltip:
                                          '${expanded ? '收起' : '展开'}${department['name']}',
                                      icon: Icon(
                                        expanded
                                            ? Icons.expand_more
                                            : Icons.chevron_right,
                                        size: 18,
                                      ),
                                      onPressed: _query.isNotEmpty
                                          ? null
                                          : () => setState(() {
                                              if (expanded) {
                                                _collapsed.add(id);
                                              } else {
                                                _collapsed.remove(id);
                                              }
                                            }),
                                    )
                                  : const Icon(
                                      Icons.folder_outlined,
                                      size: 16,
                                      color: mutedColor,
                                    ),
                            ),
                            Expanded(
                              child: InkWell(
                                onTap: () => widget.onSelected(id),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                    horizontal: 4,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        str(department['name']),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      if (!widget.compact)
                                        Text(
                                          '${department['member_count'] ?? 0} 位直属成员',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: mutedColor,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (widget.compact)
                              Tooltip(
                                message:
                                    '${department['member_count'] ?? 0} 位直属成员',
                                child: Text(
                                  '${department['member_count'] ?? 0}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: mutedColor,
                                  ),
                                ),
                              ),
                            if (widget.actions != null)
                              widget.actions!(department),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class EnterpriseMemberDetails extends StatefulWidget {
  const EnterpriseMemberDetails({
    super.key,
    required this.controller,
    required this.memberId,
    this.memberIds = const [],
    required this.onEdit,
  });
  final EnterpriseState controller;
  final String memberId;
  final List<String> memberIds;
  final Future<void> Function(Json) onEdit;
  @override
  State<EnterpriseMemberDetails> createState() =>
      _EnterpriseMemberDetailsState();
}

class _EnterpriseMemberDetailsState extends State<EnterpriseMemberDetails> {
  Json? _member;
  bool _loading = true;
  String? _error;
  int _request = 0;
  int _tab = 0;
  late String _memberId;
  late final List<String> _memberIds;
  bool _editing = false, _closed = false;
  EnterpriseState get e => widget.controller;
  @override
  void initState() {
    super.initState();
    _memberId = widget.memberId;
    _memberIds = {widget.memberId, ...widget.memberIds}.toList();
    if (widget.memberIds.contains(widget.memberId)) {
      _memberIds
        ..clear()
        ..addAll(widget.memberIds.toSet());
    }
    _load();
  }

  bool get _current =>
      mounted && !_closed && e.current && e.can('access_admin');
  bool get _routeCurrent => ModalRoute.of(context)?.isCurrent != false;
  void _close() {
    if (!mounted || _closed || !_routeCurrent) return;
    _closed = true;
    _request++;
    Navigator.pop(context);
  }

  void _step(int delta) {
    if (!_current || !_routeCurrent || _editing || _loading) return;
    final next = _memberIds.indexOf(_memberId) + delta;
    if (next < 0 || next >= _memberIds.length) return;
    setState(() {
      _memberId = _memberIds[next];
      _member = null;
    });
    _load();
  }

  Future<void> _edit(Json member) async {
    if (!_current ||
        !_routeCurrent ||
        _editing ||
        _loading ||
        !e.canEditMember(member)) {
      return;
    }
    setState(() => _editing = true);
    try {
      await widget.onEdit(member);
      if (_current) await _load();
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _load() async {
    if (!_current) return;
    final request = ++_request;
    final memberId = _memberId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final member = await e.readMember(memberId);
      if (_current && request == _request && memberId == _memberId) {
        setState(() => _member = member);
      }
    } catch (error) {
      if (mounted && request == _request) {
        setState(() {
          _member = null;
          _error = friendlyError(error);
        });
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([e, e.office]),
    builder: (context, _) {
      final available = _current, member = _member;
      final mobile = MediaQuery.sizeOf(context).width < 600;
      final index = _memberIds.indexOf(_memberId);
      Widget field(String title, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 11, color: mutedColor),
            ),
            const SizedBox(height: 5),
            SelectableText(
              value.isEmpty ? '未填写' : value,
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
      );
      final body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '成员详情',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                for (final step in [-1, 1])
                  IconButton(
                    tooltip: step < 0 ? '上一个成员' : '下一个成员',
                    onPressed:
                        available &&
                            !_loading &&
                            !_editing &&
                            index + step >= 0 &&
                            index + step < _memberIds.length
                        ? () => _step(step)
                        : null,
                    icon: Icon(
                      step < 0 ? Icons.chevron_left : Icons.chevron_right,
                      size: 19,
                    ),
                  ),
                if (available)
                  IconButton(
                    tooltip: '刷新成员详情',
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh, size: 19),
                  ),
                IconButton(
                  tooltip: '关闭成员详情',
                  onPressed: _close,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_loading && available)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: !available
                  ? const Text('当前身份或企业权限已变化，请重新打开企业管理。')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        BusinessError(_error),
                        if (member != null) ...[
                          Row(
                            children: [
                              PersonAvatar(
                                name: str(member['name']),
                                agent: member['kind'] == 'agent',
                                size: 48,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  str(member['name']),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IdentityBadge(agent: member['kind'] == 'agent'),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Icon(
                                Icons.verified_outlined,
                                size: 15,
                                color: member['status'] == 'active'
                                    ? accentColor
                                    : mutedColor,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                enterpriseStatus(member['status']),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: mutedColor,
                                ),
                              ),
                              const Spacer(),
                              if (_memberIds.length > 1)
                                Text(
                                  '当前筛选页 ${index + 1}/${_memberIds.length}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: mutedColor,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              for (final item in [(0, '基本信息'), (1, '工作信息')])
                                Expanded(
                                  child: InkWell(
                                    key: ValueKey(
                                      'member-detail-tab-${item.$1}',
                                    ),
                                    onTap: () => setState(() => _tab = item.$1),
                                    child: Container(
                                      alignment: Alignment.center,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border(
                                          bottom: BorderSide(
                                            width: _tab == item.$1 ? 2 : 1,
                                            color: _tab == item.$1
                                                ? accentColor
                                                : borderColor,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        item.$2,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: _tab == item.$1
                                              ? accentColor
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .onSurface,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_tab == 0) ...[
                            field('管理角色', enterpriseRole(member['role'])),
                            field('账号状态', enterpriseStatus(member['status'])),
                          ] else ...[
                            field(
                              '所属部门',
                              enterpriseDepartmentPath(
                                e.departments,
                                member['department_id'] as String?,
                              ),
                            ),
                            field(
                              '任职组织',
                              str(
                                member['organization_name'],
                                str(e.enterprise['name']),
                              ),
                            ),
                            field('职业', str(member['profession'])),
                            field('职位', str(member['job_title'])),
                            if (str(member['source_organization_name'])
                                .isNotEmpty)
                              field(
                                '来源组织',
                                str(member['source_organization_name']),
                              ),
                            if (member['created_at'] != null)
                              field(
                                '加入时间',
                                clockText(
                                  member['created_at'],
                                  date: true,
                                  context: context,
                                ),
                              ),
                          ],
                          if (_tab == 0) ...[
                            field(
                              '成员编号',
                              str(member['principal_id'], str(member['id'])),
                            ),
                            TextButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: _memberId),
                                );
                                if (context.mounted) {
                                  notifyOffice(context, '成员编号已复制');
                                }
                              },
                              icon: const Icon(Icons.copy_outlined, size: 16),
                              label: const Text('复制成员编号'),
                            ),
                          ],
                        ],
                      ],
                    ),
            ),
          ),
          if (available && member != null && e.canEditMember(member))
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _loading || _editing ? null : () => _edit(member),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('编辑成员资料'),
                ),
              ),
            ),
        ],
      );
      return mobile
          ? Dialog.fullscreen(child: SafeArea(child: body))
          : Dialog(
              alignment: Alignment.centerRight,
              insetPadding: EdgeInsets.zero,
              shape: const RoundedRectangleBorder(),
              child: SizedBox(
                key: const ValueKey('enterprise-member-drawer'),
                width: 480,
                height: double.infinity,
                child: body,
              ),
            );
    },
  );
}
