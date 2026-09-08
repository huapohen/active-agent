import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import '../enterprise_state.dart';
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'enterprise_apps.dart';
import 'enterprise_console_chrome.dart';
import 'enterprise_directory.dart';
import 'enterprise_organizations.dart';
import 'professional_identity.dart';

String enterpriseRole(dynamic value) =>
    const {'owner': '企业所有者', 'admin': '企业管理员', 'member': '普通成员'}[value] ??
    str(value, '未分配角色');
String enterpriseStatus(dynamic value) =>
    const {'active': '正常', 'disabled': '已停用', 'revoked': '已撤销'}[value] ??
    str(value);
const enterprisePermissions = {
  'access_admin': '访问管理后台',
  'manage_members': '管理普通成员',
  'manage_departments': '管理部门',
  'assign_admin': '分配管理员角色',
  'assign_owner': '分配企业所有者',
  'view_audit': '查看管理审计',
  'manage_enterprise': '编辑企业信息',
  'manage_apps': '管理企业应用策略',
  'manage_organizations': '管理组织目录',
};

class OfficeEnterprise extends StatefulWidget {
  const OfficeEnterprise({
    super.key,
    required this.state,
    this.controller,
    this.onClose,
  });
  final OfficeState state;
  final EnterpriseState? controller;
  final VoidCallback? onClose;
  @override
  State<OfficeEnterprise> createState() => _OfficeEnterpriseState();
}

class _OfficeEnterpriseState extends State<OfficeEnterprise> {
  late final EnterpriseState e =
      widget.controller ?? EnterpriseState(widget.state);
  int _tab = 0;
  bool _busy = false;
  bool _mobileCloseStarted = false;
  Timer? _searchTimer;
  final _memberSearch = TextEditingController();
  String? _error;
  static const _labels = enterpriseConsoleLabels;

  void _navigate(int tab) {
    if (!e.current || !e.can('access_admin')) return;
    setState(() => _tab = tab);
  }

  @override
  void initState() {
    super.initState();
    _memberSearch.text = e.memberQuery;
    e.load();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _memberSearch.dispose();
    if (widget.controller == null) e.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _searchMembers(String query) async {
    try {
      await e.loadMembers(page: 1, query: query);
    } catch (error) {
      if (mounted && e.memberQuery == query) {
        setState(() => _error = friendlyError(error));
      }
    }
  }

  Future<void> _searchAudit(String query) async {
    try {
      await e.loadAudit(page: 1, query: query);
    } catch (error) {
      if (mounted && e.auditQuery == query) {
        setState(() => _error = friendlyError(error));
      }
    }
  }

  Future<void> _export() => _run(() async {
    final content = await widget.state.officeTextRequest(
      '/enterprise/admin/export',
    );
    final bytes = Uint8List.fromList(utf8.encode(content));
    if (!mounted) return;
    final saved = await FilePicker.saveFile(
      fileName:
          'enterprise-${DateTime.now().toIso8601String().substring(0, 10)}.md',
      bytes: bytes,
      mimeType: 'text/markdown',
    );
    if (saved != null && mounted) notifyOffice(context, '企业管理文档已导出');
  });
  Future<void> _editMember([Json? member]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _EnterpriseMemberForm(controller: e, member: member),
    );
  }

  Future<void> _memberDetails(Json member) => showDialog<void>(
    context: context,
    builder: (_) => EnterpriseMemberDetails(
      controller: e,
      memberId: str(member['principal_id'], str(member['id'])),
      memberIds: e.members
          .map((item) => str(item['principal_id'], str(item['id'])))
          .toList(),
      onEdit: _editMember,
    ),
  );

  void _browseDepartment(String? id, {bool resetFilters = false}) {
    if (resetFilters) {
      _searchTimer?.cancel();
      _memberSearch.clear();
      setState(() => _tab = 1);
    }
    _run(
      () => e.loadMembers(
        page: 1,
        department: id,
        clearDepartment: id == null,
        query: resetFilters ? '' : null,
        role: resetFilters ? 'all' : null,
        status: resetFilters ? 'all' : null,
        clearOrganization: resetFilters,
      ),
    );
  }

  Future<void> _department([Json? department]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _EnterpriseDepartmentForm(controller: e, department: department),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: e,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) return _mobileEnterprise();
        final wide = constraints.maxWidth >= 760;
        return Column(
          children: [
            EnterpriseConsoleHeader(
              enterpriseName: str(e.enterprise['name'], '企业管理'),
              principalName: str(widget.state.me?['name']),
              role: enterpriseRole(e.membership['role']),
              agent: widget.state.me?['kind'] == 'agent',
              onNavigate: e.current && e.can('access_admin') ? _navigate : null,
              onRefresh: e.loading ? null : e.load,
              onExport: e.can('access_admin') && !_busy ? _export : null,
            ),
            const Divider(height: 1),
            if (e.loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null || e.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: BusinessError(_error ?? e.error),
              ),
            Expanded(
              child: !e.loaded && e.loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : !e.can('access_admin')
                  ? _noAccess()
                  : Row(
                      children: [
                        if (wide)
                          EnterpriseConsoleNavigation(
                            selected: _tab,
                            expandedWidth: constraints.maxWidth < 1000
                                ? 176
                                : 200,
                            onSelected: _navigate,
                          ),
                        Expanded(
                          child: ColoredBox(
                            color: const Color(0xfff5f6f7),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (!wide)
                                  SizedBox(
                                    height: 58,
                                    child: ListView(
                                      scrollDirection: Axis.horizontal,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                      children: List.generate(
                                        _labels.length,
                                        (i) => Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: ChoiceChip(
                                            label: Text(
                                              _labels[i],
                                              style: const TextStyle(
                                                fontSize: 13,
                                              ),
                                            ),
                                            selected: _tab == i,
                                            showCheckmark: false,
                                            onSelected: (_) => _navigate(i),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (_tab != 0)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      15,
                                      20,
                                      12,
                                    ),
                                    child: Text(
                                      '${switch (_tab) {
                                        1 || 2 || 3 || 6 => '组织架构',
                                        5 => '应用管理',
                                        _ => '管理记录',
                                      }}  ›  ${_labels[_tab]}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: mutedColor,
                                      ),
                                    ),
                                  ),
                                Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      _tab == 0 ? 0 : 12,
                                      0,
                                      _tab == 0 ? 0 : 12,
                                      _tab == 0 ? 0 : 12,
                                    ),
                                    child: Material(
                                      color: _tab == 0
                                          ? Colors.transparent
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                      clipBehavior: Clip.antiAlias,
                                      child: switch (_tab) {
                                        0 => _overview(),
                                        1 => _members(),
                                        2 => _departments(),
                                        3 => _roles(),
                                        5 => OfficeEnterpriseApps(
                                          controller: e,
                                        ),
                                        6 => OfficeOrganizations(controller: e),
                                        _ => _audit(),
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    ),
  );

  String get _mobileTitle => switch (_tab) {
    0 => '企业管理',
    7 => '管理后台',
    8 => '企业概览',
    _ => _labels[_tab],
  };

  void _closeMobileEnterprise() {
    if (!e.current || _mobileCloseStarted) return;
    if (widget.onClose != null) {
      _mobileCloseStarted = true;
      widget.onClose!();
    } else if (Navigator.of(context).canPop()) {
      _mobileCloseStarted = true;
      Navigator.of(context).pop();
    }
  }

  Future<void> _mobileInformation(String title, String description) async {
    if (!e.current || !e.can('access_admin')) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(
            description,
            style: const TextStyle(fontSize: 15, height: 1.7),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _mobileEnterprise() => Column(
    children: [
      Material(
        color: Colors.white,
        child: SizedBox(
          key: const ValueKey('enterprise-mobile-header'),
          width: double.infinity,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 90),
                child: Text(
                  _mobileTitle,
                  key: const ValueKey('enterprise-mobile-title'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_tab != 0)
                Positioned(
                  left: 4,
                  child: IconButton(
                    tooltip: '返回企业管理',
                    onPressed: () {
                      if (e.current) setState(() => _tab = 0);
                    },
                    icon: const Icon(Icons.arrow_back_ios_new, size: 19),
                  ),
                ),
              Positioned(
                right: 10,
                child: Row(
                  children: [
                    SizedBox(
                      key: const ValueKey('enterprise-mobile-more'),
                      width: 44,
                      height: 44,
                      child: PopupMenuButton<String>(
                        tooltip: '企业管理更多操作',
                        icon: const Icon(
                          Icons.more_horiz,
                          size: 22,
                          color: inkColor,
                        ),
                        color: Colors.white,
                        onSelected: (action) {
                          if (!e.current) return;
                          switch (action) {
                            case 'refresh':
                              e.load();
                            case 'export':
                              if (e.can('access_admin')) _export();
                            case 'console':
                              _navigate(7);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'refresh',
                            enabled: !e.loading,
                            child: const ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.refresh, size: 19),
                              title: Text('刷新企业信息'),
                            ),
                          ),
                          if (e.can('access_admin')) ...[
                            PopupMenuItem(
                              value: 'export',
                              enabled: !_busy,
                              child: const ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.download_outlined,
                                  size: 19,
                                ),
                                title: Text('导出企业管理文档'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'console',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.desktop_windows_outlined,
                                  size: 19,
                                ),
                                title: Text('管理后台'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(
                      key: const ValueKey('enterprise-mobile-close'),
                      width: 44,
                      height: 44,
                      child: IconButton(
                        tooltip: '关闭企业管理',
                        onPressed:
                            widget.onClose != null ||
                                Navigator.of(context).canPop()
                            ? _closeMobileEnterprise
                            : null,
                        icon: const Icon(Icons.close, size: 22),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const Divider(height: .5, thickness: .5, color: Color(0xfff0f0f0)),
      if (e.loading) const LinearProgressIndicator(minHeight: 2),
      if (_error != null || e.error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: BusinessError(_error ?? e.error),
        ),
      Expanded(
        child: !e.can('access_admin')
            ? _noAccess()
            : switch (_tab) {
                0 => _mobileOverview(),
                1 => _members(),
                2 => _departments(),
                3 => _roles(),
                5 => OfficeEnterpriseApps(controller: e),
                6 => OfficeOrganizations(controller: e),
                7 => _mobileAdminMenu(),
                8 => _overview(),
                _ => _audit(),
              },
      ),
    ],
  );

  Widget _mobileAdminMenu() => Material(
    color: Colors.white,
    child: ListView(
      key: const ValueKey('enterprise-mobile-admin-menu'),
      children: [
        for (var i = 0; i < _labels.length; i++)
          ListTile(
            key: ValueKey('enterprise-mobile-destination-$i'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 3,
            ),
            leading: Icon(
              enterpriseConsoleIcons[i],
              color: accentColor,
              size: 22,
            ),
            title: Text(_labels[i], style: const TextStyle(fontSize: 17)),
            trailing: const Icon(
              Icons.chevron_right,
              color: mutedColor,
              size: 20,
            ),
            onTap: () => _navigate(i == 0 ? 8 : i),
          ),
      ],
    ),
  );

  Widget _mobileOverview() {
    Widget entry(
      String title,
      IconData icon, {
      String? value,
      VoidCallback? onTap,
      Color color = accentColor,
      bool copy = false,
      Key? key,
    }) => Material(
      color: Colors.white,
      child: InkWell(
        key: key,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  flex: value == null ? 1 : 5,
                  child: Text(title, style: const TextStyle(fontSize: 17)),
                ),
                if (value != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 6,
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 13, color: mutedColor),
                    ),
                  ),
                ],
                if (onTap != null) ...[
                  const SizedBox(width: 10),
                  Icon(
                    copy ? Icons.copy_outlined : Icons.chevron_right,
                    size: copy ? 16 : 20,
                    color: copy ? accentColor : mutedColor,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    Widget section(String? title, List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Container(
            color: const Color(0xfff5f6f7),
            padding: const EdgeInsets.fromLTRB(18, 7, 18, 6),
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, color: mutedColor),
            ),
          ),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            const Divider(
              height: .5,
              thickness: .5,
              color: Color(0xfff0f0f0),
              indent: 54,
              endIndent: 18,
            ),
          children[i],
        ],
      ],
    );
    return Material(
      color: const Color(0xfff5f6f7),
      child: SingleChildScrollView(
        key: const ValueKey('enterprise-mobile-home'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 7),
            section(null, [
              entry(
                '企业名称',
                Icons.apartment_outlined,
                value: str(e.enterprise['name']),
                color: const Color(0xff65bf61),
                onTap: e.can('manage_enterprise')
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) => _EnterpriseProfile(controller: e),
                      )
                    : null,
              ),
              entry(
                '企业编号',
                Icons.badge_outlined,
                value: str(e.enterprise['id']),
                color: const Color(0xff50b8ac),
                copy: true,
                onTap: () async {
                  if (!e.current) return;
                  await Clipboard.setData(
                    ClipboardData(text: str(e.enterprise['id'])),
                  );
                  if (mounted && e.current) notifyOffice(context, '企业编号已复制');
                },
              ),
              entry(
                '企业认证',
                Icons.verified_user_outlined,
                value: '未接入',
                color: const Color(0xff50b8ac),
                onTap: () => _mobileInformation(
                  '企业认证',
                  '当前工作空间尚未接入企业认证服务。企业管理员角色与企业认证是不同能力，本页面不代表企业已认证。',
                ),
              ),
              entry(
                '更多企业信息',
                Icons.article_outlined,
                onTap: () => _mobileInformation(
                  '更多企业信息',
                  '${str(e.enterprise['name'])}\n企业编号：${str(e.enterprise['id'])}\n创建时间：${fullOfficeTime(e.enterprise['created_at'], context: context)}\n最近更新：${fullOfficeTime(e.enterprise['updated_at'], context: context)}\n\n人类成员 ${str(e.counts['humans'], '—')} · Agent 成员 ${str(e.counts['agents'], '—')}',
                ),
              ),
            ]),
            section('通讯录', [
              entry(
                '成员与部门',
                Icons.account_tree_outlined,
                key: const ValueKey('enterprise-mobile-members'),
                color: const Color(0xff53bfad),
                onTap: () => _navigate(1),
              ),
              if (e.can('manage_members'))
                entry(
                  '添加企业成员',
                  Icons.group_add_outlined,
                  onTap: () => _editMember(),
                ),
              entry(
                '关联组织',
                Icons.corporate_fare_outlined,
                color: const Color(0xff9166e8),
                onTap: () => _navigate(6),
              ),
            ]),
            section('企业信息', [
              entry(
                '管理员权限',
                Icons.admin_panel_settings_outlined,
                color: const Color(0xffefa245),
                onTap: () => _navigate(3),
              ),
            ]),
            section('使用帮助', [
              entry(
                '帮助中心',
                Icons.business_center_outlined,
                onTap: () => _mobileInformation(
                  '企业管理帮助',
                  '成员与部门：管理人类和 Agent 的资料、账号状态与部门归属。\n\n管理员权限：查看当前企业角色的真实权限范围。\n\n管理后台：进入企业应用、组织目录和管理日志。人类和 Agent 使用同一套企业管理权限。',
                ),
              ),
              entry(
                '在线客服',
                Icons.headset_mic_outlined,
                value: '未接入',
                color: const Color(0xfff36b76),
                onTap: () => _mobileInformation(
                  '在线客服',
                  '当前工作空间尚未配置在线客服服务。可先查看帮助中心；企业管理权限与账号问题请联系当前企业管理员。',
                ),
              ),
            ]),
            section('更多管理功能', [
              entry(
                '管理后台',
                Icons.desktop_windows_outlined,
                key: const ValueKey('enterprise-mobile-console'),
                color: const Color(0xff9166e8),
                onTap: () => _navigate(7),
              ),
            ]),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }

  Widget _noAccess() => ListView(
    padding: const EdgeInsets.all(25),
    children: [
      BusinessCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.lock_outline, size: 35, color: mutedColor),
            const SizedBox(height: 17),
            Text(
              e.loaded ? '当前身份没有企业管理权限' : '无法读取企业管理信息',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 13),
            Text(
              '当前身份：${str(widget.state.me?['name'])}\n当前角色：${enterpriseRole(e.membership['role'])}',
              style: const TextStyle(fontSize: 12, height: 1.9),
            ),
            const SizedBox(height: 13),
            const Text(
              '请由企业所有者分配管理员角色。人和 Agent 管理员遵循相同的权限规则。',
              style: TextStyle(fontSize: 12, color: mutedColor, height: 1.8),
            ),
          ],
        ),
      ),
    ],
  );
  Widget _overview() => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1040
          ? 3
          : constraints.maxWidth >= 600
          ? 2
          : 1;
      final cardWidth =
          (constraints.maxWidth - 32 - (columns - 1) * 12) / columns;
      Widget action(String label, IconData icon, int tab) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20, color: accentColor),
        title: Text(label, style: const TextStyle(fontSize: 13)),
        trailing: const Icon(Icons.chevron_right, size: 17, color: mutedColor),
        onTap: () => _navigate(tab),
      );
      Widget statistic(String label, String value, {String? detail}) =>
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: mutedColor),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
                if (detail != null)
                  Text(
                    detail,
                    style: const TextStyle(fontSize: 11, color: mutedColor),
                  ),
              ],
            ),
          );
      Widget panel(String title, List<Widget> children) => SizedBox(
        width: cardWidth,
        child: BusinessCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      );
      return ListView(
        key: const ValueKey('enterprise-overview-dashboard'),
        padding: const EdgeInsets.all(16),
        children: [
          BusinessCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: accentColor,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initial(str(e.enterprise['name'])),
                        style: const TextStyle(
                          fontSize: 23,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            str(e.enterprise['name']),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          SelectableText(
                            '企业编号：${str(e.enterprise['id'])}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: mutedColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (e.can('manage_enterprise'))
                      TextButton.icon(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => _EnterpriseProfile(controller: e),
                        ),
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('编辑企业信息'),
                      ),
                  ],
                ),
                const Divider(height: 32),
                Row(
                  children: [
                    statistic('组织总人数', str(e.counts['members'], '—')),
                    statistic('部门数', str(e.counts['departments'], '—')),
                    statistic('企业所有者', str(e.counts['owners'], '—')),
                    statistic('管理员', str(e.counts['admins'], '—')),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xfff5f7fa),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '人类成员 ${str(e.counts['humans'], '—')}  ·  Agent 成员 ${str(e.counts['agents'], '—')}  ·  按同一企业角色授权',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff646a73),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              panel('成员与组织', [
                Row(
                  children: [
                    statistic('正常成员', str(e.counts['active'], '—')),
                    statistic('已停用', str(e.counts['disabled'], '—')),
                  ],
                ),
                const SizedBox(height: 12),
                action('成员与组织', Icons.people_outline, 1),
                action('部门管理', Icons.account_tree_outlined, 2),
                action('组织管理', Icons.corporate_fare_outlined, 6),
              ]),
              panel('应用管理', [
                const Text(
                  '管理已接入应用的实际可用范围。人和 Agent 使用相同的应用策略。',
                  style: TextStyle(
                    fontSize: 12,
                    color: mutedColor,
                    height: 1.7,
                  ),
                ),
                const SizedBox(height: 12),
                action('企业应用', Icons.apps_outlined, 5),
                const Divider(height: 24),
                Text(
                  '最近更新：${fullOfficeTime(e.enterprise['updated_at'], context: context)}',
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              ]),
              panel('当前管理身份', [
                Row(
                  children: [
                    PersonAvatar(
                      name: str(widget.state.me?['name']),
                      agent: widget.state.me?['kind'] == 'agent',
                      size: 36,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            str(widget.state.me?['name']),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            enterpriseRole(e.membership['role']),
                            style: const TextStyle(
                              fontSize: 12,
                              color: mutedColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                action('角色与权限', Icons.admin_panel_settings_outlined, 3),
                if (e.can('view_audit')) action('管理日志', Icons.history, 4),
                const Text(
                  '至少保留一名有效企业所有者。',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ]),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '创建时间：${fullOfficeTime(e.enterprise['created_at'], context: context)}',
            style: const TextStyle(fontSize: 11, color: mutedColor),
          ),
        ],
      );
    },
  );
  Widget _members() => LayoutBuilder(
    builder: (context, constraints) {
      final showTree = constraints.maxWidth >= 600;
      final content = Row(
        children: [
          if (showTree) _departmentTree(),
          Expanded(
            child: Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .65,
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  str(e.enterprise['name'], '成员与组织'),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (e.can('manage_members'))
                                FilledButton.icon(
                                  onPressed: () => _editMember(),
                                  icon: const Icon(
                                    Icons.person_add_alt,
                                    size: 16,
                                  ),
                                  label: const Text('添加成员'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _memberSearch,
                            decoration: const InputDecoration(
                              hintText: '搜索姓名、成员 ID、职业或组织',
                              prefixIcon: Icon(Icons.search, size: 18),
                            ),
                            onChanged: (query) {
                              _searchTimer?.cancel();
                              _searchTimer = Timer(
                                const Duration(milliseconds: 350),
                                () => _searchMembers(query),
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              SizedBox(
                                width: showTree ? 120 : 145,
                                child: DropdownButtonFormField<String>(
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: inkColor,
                                  ),
                                  key: ValueKey(
                                    'member-status-${e.memberStatus}',
                                  ),
                                  isExpanded: true,
                                  initialValue: e.memberStatus,
                                  decoration: const InputDecoration(
                                    labelText: '账号状态',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'all',
                                      child: Text('全部状态'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'active',
                                      child: Text('正常'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'disabled',
                                      child: Text('已停用'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'revoked',
                                      child: Text('已撤销'),
                                    ),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (value) => _run(
                                          () => e.loadMembers(
                                            page: 1,
                                            status: value,
                                          ),
                                        ),
                                ),
                              ),
                              SizedBox(
                                width: showTree ? 120 : 145,
                                child: DropdownButtonFormField<String>(
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: inkColor,
                                  ),
                                  key: ValueKey('member-role-${e.memberRole}'),
                                  isExpanded: true,
                                  initialValue: e.memberRole,
                                  decoration: const InputDecoration(
                                    labelText: '管理角色',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'all',
                                      child: Text('全部角色'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'owner',
                                      child: Text('企业所有者'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'admin',
                                      child: Text('管理员'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'member',
                                      child: Text('普通成员'),
                                    ),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (value) => _run(
                                          () => e.loadMembers(
                                            page: 1,
                                            role: value,
                                          ),
                                        ),
                                ),
                              ),
                              SizedBox(
                                width: showTree ? 120 : 145,
                                child: DropdownButtonFormField<String>(
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: inkColor,
                                  ),
                                  key: ValueKey(
                                    'member-organization-${e.memberOrganization}',
                                  ),
                                  initialValue: e.memberOrganization ?? 'all',
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '任职组织',
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                      value: 'all',
                                      child: Text('全部组织'),
                                    ),
                                    ...e.organizations.map(
                                      (organization) => DropdownMenuItem(
                                        value: str(organization['id']),
                                        child: Text(
                                          str(organization['name']),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (value) => _run(
                                          () => e.loadMembers(
                                            page: 1,
                                            organization: value == 'all'
                                                ? null
                                                : value,
                                            clearOrganization: value == 'all',
                                          ),
                                        ),
                                ),
                              ),
                              if (!showTree)
                                SizedBox(
                                  width: showTree ? 120 : 145,
                                  child: DropdownButtonFormField<String>(
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: inkColor,
                                    ),
                                    key: ValueKey(
                                      'member-department-${e.memberDepartment}',
                                    ),
                                    isExpanded: true,
                                    initialValue: e.memberDepartment ?? 'all',
                                    decoration: const InputDecoration(
                                      labelText: '部门',
                                    ),
                                    items: [
                                      const DropdownMenuItem(
                                        value: 'all',
                                        child: Text('全部部门'),
                                      ),
                                      ...e.departments.map(
                                        (department) => DropdownMenuItem(
                                          value: str(department['id']),
                                          child: Text(str(department['name'])),
                                        ),
                                      ),
                                    ],
                                    onChanged: _busy
                                        ? null
                                        : (value) => _run(
                                            () => e.loadMembers(
                                              page: 1,
                                              department: value == 'all'
                                                  ? null
                                                  : value,
                                              clearDepartment: value == 'all',
                                            ),
                                          ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '共 ${e.memberTotal} 位成员${e.memberDepartment == null ? '' : ' · 仅展示部门直属成员'}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: mutedColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                const Divider(height: 1),
                Expanded(
                  child: e.members.isEmpty
                      ? const EmptyOffice(
                          title: '没有匹配的成员',
                          subtitle: '调整搜索条件，或添加人和 Agent 成员。',
                          icon: Icons.people_outline,
                        )
                      : LayoutBuilder(
                          builder: (context, box) =>
                              showTree || box.maxWidth >= 600
                              ? _memberTable()
                              : ListView(
                                  key: const ValueKey(
                                    'enterprise-members-list',
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                  ),
                                  children: e.members
                                      .map(
                                        (member) => Material(
                                          color: Colors.white,
                                          child: ListTile(
                                            onTap: () => _memberDetails(member),
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  vertical: 8,
                                                ),
                                            leading: PersonAvatar(
                                              name: str(member['name']),
                                              agent: member['kind'] == 'agent',
                                              size: 44,
                                            ),
                                            title: Text(
                                              str(member['name']),
                                              style: const TextStyle(
                                                fontSize: 17,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            subtitle: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '${enterpriseRole(member['role'])} · ${enterpriseStatus(member['status'])}${member['kind'] == 'agent' ? ' · Agent' : ''}',
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    color: mutedColor,
                                                    height: 1.8,
                                                  ),
                                                ),
                                                ProfessionalIdentity(
                                                  person: member,
                                                  enterpriseName: str(
                                                    e.enterprise['name'],
                                                  ),
                                                ),
                                              ],
                                            ),
                                            trailing: e.canEditMember(member)
                                                ? IconButton(
                                                    tooltip: '编辑成员',
                                                    onPressed: () =>
                                                        _editMember(member),
                                                    icon: const Icon(
                                                      Icons.edit_outlined,
                                                      size: 17,
                                                    ),
                                                  )
                                                : null,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                ),
                _pagination(
                  e.memberPage,
                  e.memberTotal,
                  (page) => _run(() => e.loadMembers(page: page)),
                ),
              ],
            ),
          ),
        ],
      );
      return Theme(
        data: Theme.of(context).copyWith(
          inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(5),
              borderSide: const BorderSide(color: Color(0xffdee0e3)),
            ),
            labelStyle: const TextStyle(fontSize: 12, color: mutedColor),
          ),
        ),
        child: Column(
          children: [
            if (constraints.maxWidth >= 600) ...[
              Container(
                key: const ValueKey('enterprise-members-header'),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                alignment: Alignment.centerLeft,
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '成员与组织',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      '管理人类与 Agent 的账号状态、部门归属、职业和组织信息',
                      style: TextStyle(fontSize: 12, color: mutedColor),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
            Expanded(child: content),
          ],
        ),
      );
    },
  );
  Widget _departmentTree() => Container(
    width: 210,
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: borderColor)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 8, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '组织架构',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (e.can('manage_departments'))
                IconButton(
                  tooltip: '新建部门',
                  onPressed: () => _department(),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                ),
            ],
          ),
        ),
        Expanded(
          child: EnterpriseDepartmentBrowser(
            departments: e.departments,
            selectedId: e.memberDepartment,
            compact: true,
            onSelected: _browseDepartment,
          ),
        ),
      ],
    ),
  );
  Widget _memberTable() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: SingleChildScrollView(
      child: DataTable(
        headingRowHeight: 42,
        dataRowMinHeight: 56,
        dataRowMaxHeight: 66,
        columnSpacing: 20,
        horizontalMargin: 18,
        headingRowColor: const WidgetStatePropertyAll(Color(0xfff5f6f7)),
        columns: const [
          DataColumn(label: Text('姓名', style: TextStyle(fontSize: 13))),
          DataColumn(label: Text('账号状态', style: TextStyle(fontSize: 13))),
          DataColumn(label: Text('管理角色', style: TextStyle(fontSize: 13))),
          DataColumn(label: Text('部门', style: TextStyle(fontSize: 13))),
          DataColumn(label: Text('职业与职位', style: TextStyle(fontSize: 13))),
          DataColumn(label: Text('任职组织', style: TextStyle(fontSize: 13))),
          DataColumn(label: Text('操作', style: TextStyle(fontSize: 13))),
        ],
        rows: e.members
            .map(
              (member) => DataRow(
                cells: [
                  DataCell(
                    Row(
                      children: [
                        PersonAvatar(
                          name: str(member['name']),
                          agent: member['kind'] == 'agent',
                          size: 30,
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 115,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                str(member['name']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                              Text(
                                member['kind'] == 'agent' ? 'Agent' : '成员',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: mutedColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    onTap: () => _memberDetails(member),
                  ),
                  DataCell(
                    Text(
                      enterpriseStatus(member['status']),
                      style: TextStyle(
                        fontSize: 13,
                        color: member['status'] == 'active'
                            ? const Color(0xff299a6a)
                            : mutedColor,
                      ),
                    ),
                  ),
                  DataCell(
                    Text(
                      enterpriseRole(member['role']),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: 95,
                      child: Text(
                        str(member['department_name'], '未分配'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: 140,
                      child: Text(
                        [
                          str(member['profession']),
                          str(member['job_title']),
                        ].where((v) => v.isNotEmpty).join('\n'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, height: 1.8),
                      ),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: 145,
                      child: Tooltip(
                        message: str(member['source_organization_name']).isEmpty
                            ? ''
                            : '来源组织：${member['source_organization_name']}',
                        child: Text(
                          str(
                            member['organization_name'],
                            str(e.enterprise['name']),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                  DataCell(
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => _memberDetails(member),
                          child: const Text('详情'),
                        ),
                        if (e.canEditMember(member))
                          TextButton(
                            onPressed: () => _editMember(member),
                            child: const Text('编辑'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            )
            .toList(),
      ),
    ),
  );
  Widget _departments() => Column(
    children: [
      BusinessHeader(
        title: '部门管理',
        subtitle: '选择部门查看直属成员；部门筛选将重置其他成员条件。',
        actions: [
          if (e.can('manage_departments'))
            FilledButton.icon(
              onPressed: () => _department(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建部门'),
            ),
        ],
      ),
      const Divider(height: 1),
      Expanded(
        child: e.departments.isEmpty
            ? const EmptyOffice(
                title: '尚未创建部门',
                subtitle: '添加部门，组织人和 Agent 的共同工作。',
                icon: Icons.account_tree_outlined,
              )
            : EnterpriseDepartmentBrowser(
                departments: e.departments,
                showAllMembers: false,
                onSelected: (id) => _browseDepartment(id, resetFilters: true),
                actions: !e.can('manage_departments')
                    ? null
                    : (department) => PopupMenuButton<String>(
                        tooltip: '部门操作',
                        onSelected: (action) {
                          if (action == 'edit') {
                            _department(department);
                          } else {
                            _run(() => e.deleteDepartment(department));
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('编辑部门'),
                          ),
                          if ((department['member_count'] as num? ?? 0) == 0 &&
                              !e.departments.any(
                                (d) => d['parent_id'] == department['id'],
                              ))
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除空部门'),
                            ),
                        ],
                      ),
              ),
      ),
    ],
  );
  Widget _roles() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        '角色与权限',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 9),
      const Text(
        '角色与身份类型无关。人和 Agent 都可以被授权为管理员。',
        style: TextStyle(fontSize: 12, color: mutedColor, height: 1.8),
      ),
      const SizedBox(height: 22),
      ...e.roles.map(
        (role) => Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: BusinessCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.verified_user_outlined,
                      color: accentColor,
                      size: 23,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        str(role['name'], enterpriseRole(role['id'])),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) =>
                            _EnterpriseRoleDetail(controller: e, role: role),
                      ),
                      child: const Text('查看详情'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: enterprisePermissions.entries
                      .map(
                        (permission) => Chip(
                          avatar: Icon(
                            (role['capabilities'] as Map?)?[permission.key] ==
                                    true
                                ? Icons.check_circle_outline
                                : Icons.remove_circle_outline,
                            size: 14,
                            color:
                                (role['capabilities']
                                        as Map?)?[permission.key] ==
                                    true
                                ? accentColor
                                : mutedColor,
                          ),
                          label: Text(
                            permission.value,
                            style: const TextStyle(fontSize: 10),
                          ),
                          side: const BorderSide(color: borderColor),
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
  Widget _audit() => Column(
    children: [
      const BusinessHeader(title: '管理日志', subtitle: '真实管理员操作与组织变更记录'),
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 17),
        child: TextField(
          decoration: const InputDecoration(
            hintText: '搜索管理操作、目标或详情',
            prefixIcon: Icon(Icons.search, size: 18),
          ),
          onSubmitted: _searchAudit,
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: !e.can('view_audit')
            ? const EmptyOffice(
                title: '没有日志查看权限',
                subtitle: '请由企业所有者确认你的管理角色。',
                icon: Icons.lock_outline,
              )
            : e.audit.isEmpty
            ? const EmptyOffice(
                title: '暂无匹配的管理记录',
                subtitle: '组织管理操作发生后，将记录在这里。',
                icon: Icons.history,
              )
            : ListView.separated(
                padding: const EdgeInsets.all(22),
                itemCount: e.audit.length,
                separatorBuilder: (_, _) => const Divider(height: 25),
                itemBuilder: (context, index) {
                  final item = e.audit[index];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        item['actor_kind'] == 'agent'
                            ? Icons.auto_awesome_outlined
                            : Icons.manage_accounts_outlined,
                        size: 20,
                        color: accentColor,
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _auditAction(item['action']),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${fullOfficeTime(item['at'], context: context)} · ${str(e.members.where((p) => personId(p) == item['actor_id']).firstOrNull?['name'], str(item['actor_id']))}${item['actor_kind'] == 'agent' ? ' · Agent' : ''}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: mutedColor,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              _auditDescription(item),
                              style: const TextStyle(fontSize: 11, height: 1.8),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
      _pagination(
        e.auditPage,
        e.auditTotal,
        (page) => _run(() => e.loadAudit(page: page)),
      ),
    ],
  );
  String _auditAction(dynamic value) =>
      const {
        'enterprise.bootstrapped': '初始化企业所有者',
        'enterprise.profile.updated': '更新企业信息',
        'enterprise.updated': '更新企业信息',
        'enterprise.member.created': '创建成员',
        'member.created': '创建成员',
        'enterprise.member.updated': '更新成员',
        'member.updated': '更新成员',
        'member.revoked': '撤销成员',
        'enterprise.department.created': '新建部门',
        'department.created': '新建部门',
        'enterprise.department.updated': '更新部门',
        'department.updated': '更新部门',
        'enterprise.department.deleted': '删除部门',
        'department.deleted': '删除部门',
      }[value] ??
      str(value);
  String _auditDescription(Json item) {
    final details = item['details'] is Map
        ? Json.from(item['details'])
        : <String, dynamic>{};
    return details.entries
        .where(
          (entry) => !RegExp(
            r'token|secret|password|credential',
            caseSensitive: false,
          ).hasMatch(entry.key),
        )
        .map(
          (entry) =>
              '${const {'name': '姓名', 'role': '角色', 'status': '状态', 'department_id': '部门', 'changes': '变更', 'kind': '身份类型'}[entry.key] ?? entry.key}：${entry.value}',
        )
        .join('\n');
  }

  Widget _pagination(int page, int total, void Function(int) onPage) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '共 $total 条',
            style: const TextStyle(fontSize: 11, color: mutedColor),
          ),
        ),
        IconButton(
          tooltip: '上一页',
          onPressed: page <= 1 || _busy ? null : () => onPage(page - 1),
          icon: const Icon(Icons.chevron_left, size: 19),
        ),
        Text(
          '$page / ${((total + 24) ~/ 25).clamp(1, 99999)}',
          style: const TextStyle(fontSize: 11),
        ),
        IconButton(
          tooltip: '下一页',
          onPressed: page * 25 >= total || _busy
              ? null
              : () => onPage(page + 1),
          icon: const Icon(Icons.chevron_right, size: 19),
        ),
      ],
    ),
  );
}

class _EnterpriseMemberForm extends StatefulWidget {
  const _EnterpriseMemberForm({required this.controller, this.member});
  final EnterpriseState controller;
  final Json? member;
  @override
  State<_EnterpriseMemberForm> createState() => _EnterpriseMemberFormState();
}

class _EnterpriseMemberFormState extends State<_EnterpriseMemberForm> {
  late final _name = TextEditingController(text: str(widget.member?['name']));
  late final _profession = TextEditingController(
    text: str(widget.member?['profession']),
  );
  late final _jobTitle = TextEditingController(
    text: str(widget.member?['job_title']),
  );
  final _credential = TextEditingController();
  final _clientId = OfficeState.newClientId();
  late String _kind = str(widget.member?['kind'], 'human'),
      _role = str(widget.member?['role'], 'member'),
      _status = str(widget.member?['status'], 'active');
  late String? _department = widget.member?['department_id'] as String?;
  late String? _organization = widget.member?['organization_id'] as String?;
  String? _error;
  Json? _created, _baseMember, _latestMember;
  bool _busy = false, _conflict = false;
  @override
  void initState() {
    super.initState();
    _baseMember = widget.member == null ? null : Json.from(widget.member!);
  }

  EnterpriseState get e => widget.controller;
  bool get _onlyName =>
      widget.member != null &&
      e.membership['role'] == 'admin' &&
      (widget.member!['principal_id'] ?? widget.member!['id']) ==
          e.membership['principal_id'];
  @override
  void dispose() {
    _name.dispose();
    _profession.dispose();
    _jobTitle.dispose();
    _credential.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请填写成员名称');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.member == null) {
        final created = await e.createMember(
          name: _name.text.trim(),
          kind: _kind,
          departmentId: _department,
          organizationId: _organization,
          profession: _profession.text.trim(),
          jobTitle: _jobTitle.text.trim(),
          clientId: _clientId,
        );
        if (mounted) {
          setState(() => _created = Json.from(created['member'] ?? {}));
          _credential.text = str(created['token']);
        }
      } else {
        await e.updateMember(_baseMember!, {
          'name': _name.text.trim(),
          if (!_onlyName) ...{
            'role': _role,
            'status': _status,
            'department_id': _department,
            'organization_id': _organization,
            'profession': _profession.text.trim(),
            'job_title': _jobTitle.text.trim(),
          },
        });
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = friendlyError(error);
          _conflict = error is OfficeException && error.status == 409;
          _latestMember = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readLatest() async {
    setState(() {
      _busy = true;
      _latestMember = null;
    });
    try {
      final latest = await e.readMember(
        str(_baseMember?['principal_id'], str(_baseMember?['id'])),
      );
      if (mounted) {
        setState(() {
          _latestMember = latest;
          _error = e.canEditMember(latest)
              ? null
              : '该成员的状态或角色已变化，当前身份不能再编辑此成员。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _adoptLatest() => setState(() {
    _baseMember = Json.from(_latestMember!);
    _latestMember = null;
    _conflict = false;
    _error = null;
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([e, e.office]),
    builder: (context, _) =>
        !e.current ||
            !e.can('manage_members') ||
            (_baseMember != null && !e.canEditMember(_baseMember!))
        ? AlertDialog(
            title: const Text('成员管理不可用'),
            content: const Text('当前身份或企业权限已变化，请重新打开企业管理。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          )
        : _dialog(context),
  );

  Widget _dialog(BuildContext context) => AlertDialog(
    title: Text(
      _created != null
          ? '成员已创建'
          : widget.member == null
          ? '添加成员'
          : '编辑成员',
    ),
    content: SizedBox(
      width: 470,
      child: SingleChildScrollView(
        child: _created != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PersonAvatar(
                        name: str(_created?['name']),
                        agent: _created?['kind'] == 'agent',
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          str(_created?['name']),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _credential.text.isEmpty
                        ? '成员已创建，但初次访问凭据未取得。请联系工作空间管理员重新签发凭据，请勿重复创建成员。'
                        : '个人访问令牌仅在此提供一次。请妥善交给对应成员，用于高级登录或 Agent 接入。',
                    style: TextStyle(
                      fontSize: 12,
                      color: mutedColor,
                      height: 1.8,
                    ),
                  ),
                  if (_credential.text.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _credential,
                      readOnly: true,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '个人访问令牌'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: _credential.text),
                        );
                        if (context.mounted) notifyOffice(context, '个人访问令牌已复制');
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('复制个人访问令牌'),
                    ),
                  ],
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _name,
                    maxLength: 100,
                    decoration: const InputDecoration(labelText: '成员名称'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _profession,
                    enabled: !_onlyName && !_busy,
                    maxLength: 100,
                    decoration: const InputDecoration(labelText: '职业'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _jobTitle,
                    enabled: !_onlyName && !_busy,
                    maxLength: 100,
                    decoration: const InputDecoration(labelText: '职位'),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: _organization ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '任职组织'),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(str(e.enterprise['name'], '默认企业')),
                      ),
                      ...e.organizations.map(
                        (o) => DropdownMenuItem(
                          value: str(o['id']),
                          child: Text(str(o['name'])),
                        ),
                      ),
                      if (_organization != null &&
                          !e.organizations.any((o) => o['id'] == _organization))
                        DropdownMenuItem(
                          value: _organization,
                          child: Text(
                            str(widget.member?['organization_name'], '当前组织'),
                          ),
                        ),
                    ],
                    onChanged: _onlyName || _busy
                        ? null
                        : (value) => setState(
                            () => _organization = value == '' ? null : value,
                          ),
                  ),
                  if (widget.member == null) ...[
                    const SizedBox(height: 14),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'human',
                          icon: Icon(Icons.person_outline, size: 17),
                          label: Text('人类成员'),
                        ),
                        ButtonSegment(
                          value: 'agent',
                          icon: Icon(Icons.auto_awesome_outlined, size: 17),
                          label: Text('Agent 成员'),
                        ),
                      ],
                      selected: {_kind},
                      onSelectionChanged: _busy
                          ? null
                          : (value) => setState(() => _kind = value.single),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '新成员以普通成员角色加入。创建后，所有者可分配管理角色。',
                      style: TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        height: 1.8,
                      ),
                    ),
                  ],
                  const SizedBox(height: 17),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _department ?? 'none',
                    decoration: const InputDecoration(labelText: '所属部门'),
                    items: [
                      const DropdownMenuItem(
                        value: 'none',
                        child: Text('未分配部门'),
                      ),
                      ...e.departments.map(
                        (department) => DropdownMenuItem(
                          value: str(department['id']),
                          child: Text(str(department['name'])),
                        ),
                      ),
                    ],
                    onChanged: _busy || _onlyName
                        ? null
                        : (value) => setState(
                            () => _department = value == 'none' ? null : value,
                          ),
                  ),
                  if (widget.member != null) ...[
                    const SizedBox(height: 17),
                    DropdownButtonFormField<String>(
                      initialValue: _role,
                      decoration: const InputDecoration(labelText: '管理角色'),
                      items: [
                        const DropdownMenuItem(
                          value: 'member',
                          child: Text('普通成员'),
                        ),
                        if (e.can('assign_admin') || _role == 'admin')
                          const DropdownMenuItem(
                            value: 'admin',
                            child: Text('企业管理员'),
                          ),
                        if (e.can('assign_owner') || _role == 'owner')
                          const DropdownMenuItem(
                            value: 'owner',
                            child: Text('企业所有者'),
                          ),
                      ],
                      onChanged:
                          _busy ||
                              (!e.can('assign_admin') && !e.can('assign_owner'))
                          ? null
                          : (value) =>
                                setState(() => _role = value ?? 'member'),
                    ),
                    const SizedBox(height: 17),
                    DropdownButtonFormField<String>(
                      initialValue: _status,
                      decoration: const InputDecoration(labelText: '账号状态'),
                      items: const [
                        DropdownMenuItem(value: 'active', child: Text('正常')),
                        DropdownMenuItem(value: 'disabled', child: Text('停用')),
                      ],
                      onChanged: _busy || _onlyName
                          ? null
                          : (value) =>
                                setState(() => _status = value ?? 'active'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '停用后，该身份将无法继续访问工作空间。企业必须保留至少一名有效所有者。',
                      style: TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        height: 1.8,
                      ),
                    ),
                  ],
                  BusinessError(_error),
                  if (_conflict) ...[
                    const SizedBox(height: 10),
                    const Text(
                      '成员资料已被修改。你的输入已保留；先读取最新资料，确认后再提交。',
                      style: TextStyle(
                        fontSize: 12,
                        color: mutedColor,
                        height: 1.7,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _readLatest,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('读取最新成员资料'),
                    ),
                    if (_latestMember != null) ...[
                      Text(
                        '最新版本 ${_latestMember!['revision']}：${_latestMember!['name']}\n'
                        '${enterpriseRole(_latestMember!['role'])} · ${enterpriseStatus(_latestMember!['status'])}\n'
                        '${enterpriseDepartmentPath(e.departments, _latestMember!['department_id'] as String?)}\n'
                        '任职组织：${str(_latestMember!['organization_name'], str(e.enterprise['name']))}\n'
                        '职业：${str(_latestMember!['profession'], '未填写')} · 职位：${str(_latestMember!['job_title'], '未填写')}',
                        style: const TextStyle(fontSize: 12, height: 1.8),
                      ),
                      OutlinedButton(
                        onPressed: _busy || !e.canEditMember(_latestMember!)
                            ? null
                            : _adoptLatest,
                        child: const Text('保留输入并采用最新版本'),
                      ),
                    ],
                  ],
                ],
              ),
      ),
    ),
    actions: _created != null
        ? [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ]
        : [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _busy || _conflict ? null : _save,
              child: Text(
                _busy
                    ? '保存中…'
                    : widget.member == null
                    ? '创建成员'
                    : '保存变更',
              ),
            ),
          ],
  );
}

class _EnterpriseDepartmentForm extends StatefulWidget {
  const _EnterpriseDepartmentForm({required this.controller, this.department});
  final EnterpriseState controller;
  final Json? department;
  @override
  State<_EnterpriseDepartmentForm> createState() =>
      _EnterpriseDepartmentFormState();
}

class _EnterpriseDepartmentFormState extends State<_EnterpriseDepartmentForm> {
  final _clientId = OfficeState.newClientId();
  late final _name = TextEditingController(
    text: str(widget.department?['name']),
  );
  late String? _parent = widget.department?['parent_id'] as String?;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请填写部门名称');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.saveDepartment(
        department: widget.department,
        clientId: _clientId,
        name: _name.text.trim(),
        parentId: _parent,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.department == null ? '新建部门' : '编辑部门'),
    content: SizedBox(
      width: 430,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            maxLength: 100,
            decoration: const InputDecoration(labelText: '部门名称'),
          ),
          const SizedBox(height: 17),
          DropdownButtonFormField<String>(
            initialValue: _parent ?? 'root',
            decoration: const InputDecoration(labelText: '上级部门'),
            items: [
              const DropdownMenuItem(value: 'root', child: Text('企业根部门')),
              ...widget.controller.departments
                  .where(
                    (department) =>
                        department['id'] != widget.department?['id'],
                  )
                  .map(
                    (department) => DropdownMenuItem(
                      value: str(department['id']),
                      child: Text(str(department['name'])),
                    ),
                  ),
            ],
            onChanged: _busy
                ? null
                : (value) =>
                      setState(() => _parent = value == 'root' ? null : value),
          ),
          BusinessError(_error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? '保存中…' : '保存部门'),
      ),
    ],
  );
}

class _EnterpriseProfile extends StatefulWidget {
  const _EnterpriseProfile({required this.controller});
  final EnterpriseState controller;
  @override
  State<_EnterpriseProfile> createState() => _EnterpriseProfileState();
}

class _EnterpriseProfileState extends State<_EnterpriseProfile> {
  late final _name = TextEditingController(
    text: str(widget.controller.enterprise['name']),
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑企业信息'),
    content: SizedBox(
      width: 430,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            maxLength: 100,
            decoration: const InputDecoration(labelText: '企业名称'),
          ),
          BusinessError(_error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy
            ? null
            : () async {
                if (_name.text.trim().isEmpty) {
                  setState(() => _error = '请填写企业名称');
                  return;
                }
                setState(() {
                  _busy = true;
                  _error = null;
                });
                try {
                  await widget.controller.saveProfile(_name.text.trim());
                  if (context.mounted) Navigator.pop(context);
                } catch (error) {
                  if (mounted) setState(() => _error = friendlyError(error));
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
        child: Text(_busy ? '保存中…' : '保存'),
      ),
    ],
  );
}

class _EnterpriseRoleDetail extends StatelessWidget {
  const _EnterpriseRoleDetail({required this.controller, required this.role});
  final EnterpriseState controller;
  final Json role;
  @override
  Widget build(BuildContext context) => Dialog(
    alignment: Alignment.centerRight,
    insetPadding: EdgeInsets.all(
      MediaQuery.sizeOf(context).width < 600 ? 12 : 28,
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 650),
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(23, 20, 13, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      str(role['name'], enterpriseRole(role['id'])),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭角色详情',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const TabBar(
              tabs: [
                Tab(text: '权限范围'),
                Tab(text: '成员'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  ListView(
                    padding: const EdgeInsets.all(23),
                    children: enterprisePermissions.entries
                        .map(
                          (permission) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              (role['capabilities'] as Map?)?[permission.key] ==
                                      true
                                  ? Icons.check_circle_outline
                                  : Icons.remove_circle_outline,
                              color:
                                  (role['capabilities']
                                          as Map?)?[permission.key] ==
                                      true
                                  ? accentColor
                                  : mutedColor,
                              size: 20,
                            ),
                            title: Text(
                              permission.value,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              (role['capabilities'] as Map?)?[permission.key] ==
                                      true
                                  ? '允许'
                                  : '未授予',
                              style: const TextStyle(
                                fontSize: 10,
                                color: mutedColor,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  _EnterpriseRoleMembers(
                    controller: controller,
                    role: str(role['id']),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EnterpriseRoleMembers extends StatefulWidget {
  const _EnterpriseRoleMembers({required this.controller, required this.role});
  final EnterpriseState controller;
  final String role;
  @override
  State<_EnterpriseRoleMembers> createState() => _EnterpriseRoleMembersState();
}

class _EnterpriseRoleMembersState extends State<_EnterpriseRoleMembers> {
  late final Future<Json> _result = widget.controller.roleMembers(widget.role);
  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: _result,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Padding(
          padding: const EdgeInsets.all(23),
          child: BusinessError(friendlyError(snapshot.error!)),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      final people = maps(snapshot.data!['members']);
      return ListView(
        padding: const EdgeInsets.all(23),
        children: [
          Text(
            '共 ${str(snapshot.data!['total'], '0')} 位成员${(snapshot.data!['total'] as num? ?? 0) > 25 ? ' · 显示前 25 位' : ''}',
            style: const TextStyle(fontSize: 11, color: mutedColor),
          ),
          const SizedBox(height: 15),
          ...people.map(
            (member) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: PersonAvatar(
                name: str(member['name']),
                agent: member['kind'] == 'agent',
                size: 33,
              ),
              title: Text(
                str(member['name']),
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                '${enterpriseStatus(member['status'])}${member['kind'] == 'agent' ? ' · Agent' : ''}',
                style: const TextStyle(fontSize: 11, color: mutedColor),
              ),
            ),
          ),
        ],
      );
    },
  );
}
