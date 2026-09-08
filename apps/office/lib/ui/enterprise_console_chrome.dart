import 'package:flutter/material.dart';

import 'office_theme.dart';

const enterpriseConsoleLabels = [
  '企业概览',
  '成员与组织',
  '部门管理',
  '角色与权限',
  '管理日志',
  '企业应用',
  '组织管理',
];
const enterpriseConsoleIcons = [
  Icons.dashboard_outlined,
  Icons.people_outline,
  Icons.account_tree_outlined,
  Icons.admin_panel_settings_outlined,
  Icons.history,
  Icons.apps_outlined,
  Icons.corporate_fare_outlined,
];

/// The search indexes available console destinations, not private member data.
/// All callbacks are checked again by the enterprise controller's owner.
class EnterpriseConsoleHeader extends StatelessWidget {
  const EnterpriseConsoleHeader({
    super.key,
    required this.enterpriseName,
    required this.principalName,
    required this.role,
    required this.agent,
    required this.onNavigate,
    required this.onRefresh,
    this.onExport,
  });
  final String enterpriseName, principalName, role;
  final bool agent;
  final ValueChanged<int>? onNavigate;
  final VoidCallback? onRefresh, onExport;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Container(
      key: const ValueKey('enterprise-console-header'),
      height: 64,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          const AppLogo(size: 28),
          const SizedBox(width: 10),
          const Text(
            '管理后台',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 28),
          if (constraints.maxWidth >= 1000) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xfff4f5f6),
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Row(
                children: [
                  Icon(Icons.apartment_outlined, size: 17),
                  SizedBox(width: 7),
                  Text('企业管理', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 24),
          ],
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Autocomplete<int>(
                  optionsBuilder: (value) {
                    if (onNavigate == null || value.text.trim().isEmpty) {
                      return const Iterable<int>.empty();
                    }
                    final query = value.text.trim().toLowerCase();
                    const terms = [
                      '企业 概览 首页',
                      '成员 组织 人类 agent 同事 通讯录',
                      '部门 组织架构',
                      '角色 权限 管理员',
                      '管理 日志 审计',
                      '企业 应用 工作台 插件',
                      '组织 公司 agent',
                    ];
                    return List.generate(
                      enterpriseConsoleLabels.length,
                      (i) => i,
                    ).where(
                      (i) => '${enterpriseConsoleLabels[i]} ${terms[i]}'
                          .toLowerCase()
                          .contains(query),
                    );
                  },
                  displayStringForOption: (i) => enterpriseConsoleLabels[i],
                  onSelected: onNavigate,
                  fieldViewBuilder:
                      (context, controller, focusNode, onSubmitted) =>
                          TextField(
                            key: const ValueKey('enterprise-navigation-search'),
                            controller: controller,
                            focusNode: focusNode,
                            enabled: onNavigate != null,
                            style: const TextStyle(fontSize: 13),
                            decoration: const InputDecoration(
                              hintText: '搜索功能导航、组织管理、角色权限',
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              prefixIcon: Icon(Icons.search, size: 18),
                              prefixIconConstraints: BoxConstraints(
                                minWidth: 36,
                              ),
                            ),
                            onSubmitted: (_) => onSubmitted(),
                          ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (onExport != null)
            IconButton(
              tooltip: '导出企业管理文档',
              onPressed: onExport,
              icon: const Icon(Icons.download_outlined, size: 19),
            ),
          IconButton(
            tooltip: '刷新企业信息',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 19),
          ),
          const SizedBox(width: 12),
          PersonAvatar(name: principalName, agent: agent, size: 30),
          if (constraints.maxWidth >= 760) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: constraints.maxWidth < 1000 ? 120 : 142,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    enterpriseName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '$principalName · $role',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: mutedColor),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class EnterpriseConsoleNavigation extends StatefulWidget {
  const EnterpriseConsoleNavigation({
    super.key,
    required this.selected,
    required this.onSelected,
    this.expandedWidth = 200,
  });
  final int selected;
  final double expandedWidth;
  final ValueChanged<int> onSelected;
  @override
  State<EnterpriseConsoleNavigation> createState() =>
      _EnterpriseConsoleNavigationState();
}

class _EnterpriseConsoleNavigationState
    extends State<EnterpriseConsoleNavigation> {
  bool _collapsed = false;
  final _expanded = <String>{'组织架构', '应用管理', '管理记录'};

  @override
  void didUpdateWidget(covariant EnterpriseConsoleNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _expanded.add(switch (widget.selected) {
        1 || 2 || 3 || 6 => '组织架构',
        5 => '应用管理',
        _ => '管理记录',
      });
    }
  }

  Widget _destination(int index, {bool nested = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    child: Material(
      color: widget.selected == index
          ? const Color(0xffe9eaec)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(5),
      child: Tooltip(
        message: enterpriseConsoleLabels[index],
        child: InkWell(
          key: ValueKey('enterprise-nav-$index'),
          borderRadius: BorderRadius.circular(5),
          onTap: () => widget.onSelected(index),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              nested && !_collapsed ? 40 : 12,
              11,
              10,
              11,
            ),
            child: Row(
              children: [
                if (!nested || _collapsed)
                  Icon(
                    enterpriseConsoleIcons[index],
                    size: 18,
                    color: const Color(0xff646a73),
                  ),
                if (!_collapsed) ...[
                  if (!nested) const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      enterpriseConsoleLabels[index],
                      style: TextStyle(
                        fontSize: 13,
                        color: widget.selected == index
                            ? inkColor
                            : const Color(0xff646a73),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _group(String label, IconData icon, List<int> indexes) {
    if (_collapsed) {
      return Column(children: indexes.map((i) => _destination(i)).toList());
    }
    final open = _expanded.contains(label);
    return Column(
      children: [
        ListTile(
          key: ValueKey('enterprise-nav-group-$label'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          minLeadingWidth: 18,
          horizontalTitleGap: 10,
          leading: Icon(icon, size: 18, color: mutedColor),
          title: Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xff646a73)),
          ),
          trailing: Icon(
            open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
            size: 17,
            color: mutedColor,
          ),
          onTap: () => setState(
            () => open ? _expanded.remove(label) : _expanded.add(label),
          ),
        ),
        if (open) ...indexes.map((i) => _destination(i, nested: true)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('enterprise-console-navigation'),
    width: _collapsed ? 64 : widget.expandedWidth,
    child: Material(
      color: const Color(0xfff5f6f7),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 10),
              children: [
                _destination(0),
                _group('组织架构', Icons.people_outline, [1, 2, 6, 3]),
                _group('应用管理', Icons.apps_outlined, [5]),
                _group('管理记录', Icons.history, [4]),
              ],
            ),
          ),
          const Divider(height: 1),
          Tooltip(
            message: _collapsed ? '展开管理导航' : '收起管理导航',
            child: InkWell(
              key: const ValueKey('enterprise-navigation-collapse'),
              onTap: () => setState(() => _collapsed = !_collapsed),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 15,
                ),
                child: Row(
                  children: [
                    Icon(
                      _collapsed
                          ? Icons.keyboard_double_arrow_right
                          : Icons.keyboard_double_arrow_left,
                      size: 18,
                      color: mutedColor,
                    ),
                    if (!_collapsed)
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: 10),
                          child: Text(
                            '收起导航',
                            style: TextStyle(fontSize: 12, color: mutedColor),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
