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
    required this.onEdit,
  });
  final EnterpriseState controller;
  final String memberId;
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
  EnterpriseState get e => widget.controller;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final member = await e.readMember(widget.memberId);
      if (mounted && request == _request) setState(() => _member = member);
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
      final available = e.current && e.can('access_admin'), member = _member;
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
                if (available)
                  IconButton(
                    tooltip: '刷新成员详情',
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh, size: 19),
                  ),
                IconButton(
                  tooltip: '关闭成员详情',
                  onPressed: () => Navigator.pop(context),
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
                          field('管理角色', enterpriseRole(member['role'])),
                          field('账号状态', enterpriseStatus(member['status'])),
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
                          field(
                            '成员编号',
                            str(member['principal_id'], str(member['id'])),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: widget.memberId),
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
                    ),
            ),
          ),
          if (available && member != null && e.canEditMember(member))
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _loading
                      ? null
                      : () async {
                          await widget.onEdit(member);
                          if (mounted && e.current) await _load();
                        },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('编辑成员资料'),
                ),
              ),
            ),
        ],
      );
      return MediaQuery.sizeOf(context).width < 600
          ? Dialog.fullscreen(child: SafeArea(child: body))
          : Dialog(
              child: SizedBox(
                width: 580,
                height: MediaQuery.sizeOf(context).height * .86,
                child: body,
              ),
            );
    },
  );
}
