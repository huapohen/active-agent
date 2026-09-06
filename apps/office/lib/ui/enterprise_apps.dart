import 'dart:async';

import 'package:flutter/material.dart';

import '../enterprise_state.dart';
import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeEnterpriseApps extends StatefulWidget {
  const OfficeEnterpriseApps({super.key, required this.controller});
  final EnterpriseState controller;
  @override
  State<OfficeEnterpriseApps> createState() => _OfficeEnterpriseAppsState();
}

class _OfficeEnterpriseAppsState extends State<OfficeEnterpriseApps> {
  bool _loading = false;
  String? _error;
  Timer? _timer;
  String _query = '';
  EnterpriseState get e => widget.controller;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final query = _query;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await e.loadApps(query: query);
    } catch (error) {
      if (mounted && query == _query) {
        setState(() => _error = friendlyError(error));
      }
    } finally {
      if (mounted && query == _query) setState(() => _loading = false);
    }
  }

  Future<void> _open(Json app) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _EnterpriseAppPolicy(controller: e, app: app),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: e,
    builder: (context, _) => Column(
      children: [
        const BusinessHeader(title: '企业应用', subtitle: '管理工作空间应用的实际可用范围'),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索企业应用',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
            onChanged: (value) {
              _query = value;
              _timer?.cancel();
              _timer = Timer(const Duration(milliseconds: 350), _load);
            },
          ),
        ),
        const Divider(height: 1),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: BusinessError(_error),
          ),
        Expanded(
          child: e.apps.isEmpty && !_loading
              ? const EmptyOffice(
                  title: '没有找到企业应用',
                  subtitle: '调整关键词，或刷新当前应用列表。',
                  icon: Icons.apps_outlined,
                )
              : ListView(
                  padding: const EdgeInsets.all(22),
                  children: e.apps.map((app) {
                    final policy = app['policy'] is Map
                        ? Json.from(app['policy'])
                        : <String, dynamic>{};
                    final available = app['available'] == true;
                    final enabled = policy['enabled'] != false;
                    final protected = app['protected_core'] == true;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: BusinessCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: available
                                        ? selectedColor
                                        : const Color(0xfff3f4f6),
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Icon(
                                    protected
                                        ? Icons.verified_user_outlined
                                        : app['kind'] == 'hardware'
                                        ? Icons.devices_other_outlined
                                        : Icons.apps_outlined,
                                    color: available ? accentColor : mutedColor,
                                    size: 23,
                                  ),
                                ),
                                const SizedBox(width: 13),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        str(app['name']),
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        !available
                                            ? '已登记，尚未连接'
                                            : protected
                                            ? '核心模块 · 始终可用'
                                            : enabled
                                            ? '企业已启用'
                                            : '企业已停用',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: !available
                                              ? const Color(0xff9b794d)
                                              : enabled
                                              ? const Color(0xff319b6c)
                                              : mutedColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _open(app),
                                  child: Text(
                                    e.can('manage_apps') && !protected
                                        ? '配置'
                                        : '查看详情',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 13),
                            Text(
                              str(app['description']),
                              style: const TextStyle(
                                fontSize: 12,
                                color: mutedColor,
                                height: 1.8,
                              ),
                            ),
                            const SizedBox(height: 13),
                            Wrap(
                              spacing: 17,
                              runSpacing: 7,
                              children: [
                                Text(
                                  policy['scope_mode'] == 'restricted'
                                      ? '指定范围可用'
                                      : '全员可用',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                Text(
                                  '禁用成员 ${(policy['denied_principal_ids'] as List? ?? []).length} 位',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: mutedColor,
                                  ),
                                ),
                                Text(
                                  '策略 r${str(policy['revision'], '1')}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: mutedColor,
                                  ),
                                ),
                              ],
                            ),
                            if (!available)
                              const Padding(
                                padding: EdgeInsets.only(top: 10),
                                child: Text(
                                  '外部适配器尚未连接。保存企业策略不会建立外部连接。',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xff9b794d),
                                    height: 1.8,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    ),
  );
}

class _EnterpriseAppPolicy extends StatefulWidget {
  const _EnterpriseAppPolicy({required this.controller, required this.app});
  final EnterpriseState controller;
  final Json app;
  @override
  State<_EnterpriseAppPolicy> createState() => _EnterpriseAppPolicyState();
}

class _EnterpriseAppPolicyState extends State<_EnterpriseAppPolicy> {
  late Json _app = widget.app;
  late final Json _initial = Json.from(widget.app['policy'] ?? {});
  late bool _enabled = _initial['enabled'] != false;
  late String _scope = str(_initial['scope_mode'], 'all');
  late List<String>
  _allowed = List<String>.from(_initial['allowed_principal_ids'] ?? []),
  _departments = List<String>.from(_initial['allowed_department_ids'] ?? []),
  _denied = List<String>.from(_initial['denied_principal_ids'] ?? []);
  bool _busy = false;
  String? _error;
  Json? _latest;
  EnterpriseState get e => widget.controller;
  bool get _editable => e.can('manage_apps') && _app['protected_core'] != true;
  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _latest = null;
    });
    try {
      await e.configureApp(_app, {
        'enabled': _enabled,
        'scope_mode': _scope,
        'allowed_principal_ids': _allowed,
        'allowed_department_ids': _departments,
        'denied_principal_ids': _denied,
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
      if (error is OfficeException && error.status == 409) {
        try {
          final latest = await e.readApp(str(_app['id']));
          if (mounted) setState(() => _latest = latest);
        } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _people(
    List<String> values,
    void Function(List<String>) assign,
    String title,
  ) async {
    final selected = await chooseOfficePeople(
      context,
      e.office,
      selected: values,
      title: title,
    );
    if (selected != null && mounted) setState(() => assign(selected));
  }

  Future<void> _pickDepartments() async {
    final selected = _departments.toSet();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('选择可用部门'),
          content: SizedBox(
            width: 420,
            height: 330,
            child: Column(
              children: [
                const Text(
                  '仅包含选中部门的直属成员，不包含子部门。',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView(
                    children: e.departments
                        .map(
                          (department) => CheckboxListTile(
                            value: selected.contains(str(department['id'])),
                            onChanged: (value) => change(() {
                              value == true
                                  ? selected.add(str(department['id']))
                                  : selected.remove(str(department['id']));
                            }),
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              str(department['name']),
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              '${str(department['member_count'], '0')} 位直属成员',
                              style: const TextStyle(
                                fontSize: 10,
                                color: mutedColor,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected.toList()),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) setState(() => _departments = result);
  }

  String _person(String id) => str(
    e.office.principals
        .where((person) => personId(person) == id)
        .firstOrNull?['name'],
    id,
  );
  Widget _chips(
    List<String> values,
    void Function(String) remove, {
    bool departments = false,
  }) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: values
        .map(
          (id) => InputChip(
            label: Text(
              departments
                  ? str(
                      e.departments
                          .where((department) => department['id'] == id)
                          .firstOrNull?['name'],
                      id,
                    )
                  : _person(id),
              style: const TextStyle(fontSize: 11),
            ),
            onDeleted: _editable && !_busy
                ? () => setState(() => remove(id))
                : null,
            visualDensity: VisualDensity.compact,
          ),
        )
        .toList(),
  );
  @override
  Widget build(BuildContext context) => Dialog(
    alignment: Alignment.centerRight,
    insetPadding: EdgeInsets.all(
      MediaQuery.sizeOf(context).width < 600 ? 12 : 28,
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 660, maxHeight: 850),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(23, 20, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    str(_app['name']),
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭应用策略',
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(23),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_app['protected_core'] == true)
                    const BusinessCard(
                      color: Color(0xfff5f8ff),
                      child: Text(
                        '核心模块始终为所有成员保留，用于身份设置与管理恢复。不能停用或限制范围。',
                        style: TextStyle(fontSize: 12, height: 1.8),
                      ),
                    ),
                  if (_app['available'] != true)
                    const BusinessCard(
                      color: Color(0xfffff8ed),
                      child: Text(
                        '此扩展尚未连接，目前不可执行操作。企业策略仅配置允许范围。',
                        style: TextStyle(fontSize: 12, height: 1.8),
                      ),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '企业启用',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: const Text(
                      '策略保存后，对人和 Agent 成员按相同规则生效。',
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                    value: _enabled,
                    onChanged: _editable && !_busy
                        ? (value) => setState(() => _enabled = value)
                        : null,
                  ),
                  const Divider(height: 30),
                  const Text(
                    '可用范围',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 13),
                  Wrap(
                    spacing: 10,
                    children: ['all', 'restricted']
                        .map(
                          (scope) => ChoiceChip(
                            label: Text(scope == 'all' ? '全员可用' : '指定范围'),
                            selected: _scope == scope,
                            showCheckmark: false,
                            onSelected: _editable && !_busy
                                ? (_) => setState(() => _scope = scope)
                                : null,
                          ),
                        )
                        .toList(),
                  ),
                  if (_scope == 'restricted') ...[
                    const SizedBox(height: 15),
                    const Text(
                      '选定成员与选定部门的直属成员均可使用。未选择任何范围时，无成员可使用。',
                      style: TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        height: 1.8,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _chips(_allowed, (id) => _allowed.remove(id)),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: _editable && !_busy
                          ? () => _people(
                              _allowed,
                              (value) => _allowed = value,
                              '选择可用成员',
                            )
                          : null,
                      icon: const Icon(Icons.person_add_alt, size: 16),
                      label: const Text('选择人或 Agent'),
                    ),
                    const SizedBox(height: 13),
                    _chips(
                      _departments,
                      (id) => _departments.remove(id),
                      departments: true,
                    ),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: _editable && !_busy ? _pickDepartments : null,
                      icon: const Icon(Icons.account_tree_outlined, size: 16),
                      label: const Text('选择部门'),
                    ),
                  ],
                  const Divider(height: 30),
                  const Text(
                    '禁用成员',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 9),
                  const Text(
                    '禁用名单优先于可用范围。名单内的成员将无法使用此应用。',
                    style: TextStyle(
                      fontSize: 11,
                      color: mutedColor,
                      height: 1.8,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _chips(_denied, (id) => _denied.remove(id)),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: _editable && !_busy
                        ? () => _people(
                            _denied,
                            (value) => _denied = value,
                            '选择禁用成员',
                          )
                        : null,
                    icon: const Icon(Icons.person_off_outlined, size: 16),
                    label: const Text('设置禁用成员'),
                  ),
                  const Divider(height: 30),
                  const Text(
                    '应用能力',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  ...maps(_app['capabilities']).map(
                    (capability) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle_outline,
                            size: 16,
                            color: accentColor,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              str(capability['name']),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '应用策略控制入口与执行范围。文档、会话和个人数据仍遵循各自的访问权限。',
                    style: TextStyle(
                      fontSize: 11,
                      color: mutedColor,
                      height: 1.8,
                    ),
                  ),
                  BusinessError(_error),
                  if (_latest != null)
                    BusinessCard(
                      color: const Color(0xfffff8ed),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '服务器最新策略 r${(_latest!['policy'] as Map?)?['revision']}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            _policyDescription(
                              Json.from(_latest!['policy'] ?? {}),
                            ),
                            style: const TextStyle(fontSize: 11, height: 1.8),
                          ),
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed: () => setState(() {
                              _app = _latest!;
                              _latest = null;
                              _error = '已采用最新版本号，上方编辑已保留。请核对范围后保存。';
                            }),
                            child: const Text('保留编辑，以最新版本继续合并'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(17),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
                if (_editable) ...[
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _busy || _latest != null ? null : _save,
                    child: Text(_busy ? '保存中…' : '保存企业策略'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
  String _policyDescription(Json policy) =>
      '${policy['enabled'] == false ? '企业已停用' : '企业已启用'} · ${policy['scope_mode'] == 'restricted' ? '指定范围' : '全员可用'}\n可用成员：${(policy['allowed_principal_ids'] as List? ?? []).map((id) => _person(str(id))).join('、')}\n可用部门：${(policy['allowed_department_ids'] as List? ?? []).map((id) => str(e.departments.where((d) => d['id'] == id).firstOrNull?['name'], str(id))).join('、')}\n禁用成员：${(policy['denied_principal_ids'] as List? ?? []).map((id) => _person(str(id))).join('、')}';
}
