import 'package:flutter/material.dart';

import '../enterprise_state.dart';
import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeOrganizations extends StatefulWidget {
  const OfficeOrganizations({super.key, required this.controller});
  final EnterpriseState controller;
  @override
  State<OfficeOrganizations> createState() => _OfficeOrganizationsState();
}

class _OfficeOrganizationsState extends State<OfficeOrganizations> {
  String _query = '';
  String? _error;
  bool _loading = true, _busy = false;
  EnterpriseState get e => widget.controller;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await e.loadOrganizations();
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([Json? organization]) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _OrganizationForm(controller: e, organization: organization),
  );
  Future<void> _delete(Json organization) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除空组织'),
        content: Text('删除“${organization['name']}”？组织内仍有成员时，系统会拒绝删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await e.deleteOrganization(organization);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: e,
    builder: (context, _) {
      final organizations = e.organizations
          .where(
            (o) => '${o['name']} ${o['description'] ?? ''}'
                .toLowerCase()
                .contains(_query.toLowerCase()),
          )
          .toList();
      return Column(
        children: [
          BusinessHeader(
            title: '组织管理',
            subtitle: '同一工作空间内的人与 Agent 组织目录',
            actions: [
              if (e.can('manage_organizations'))
                FilledButton.icon(
                  onPressed: _busy ? null : () => _edit(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建组织'),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
            child: OfficeSearch(
              hint: '搜索组织名称与说明',
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: BusinessError(_error),
            ),
          const Divider(height: 1),
          Expanded(
            child: organizations.isEmpty && !_loading
                ? const EmptyOffice(
                    title: '暂无匹配的组织',
                    subtitle: '成员仍可归属于默认企业。组织目录不改变工作空间的访问边界。',
                    icon: Icons.corporate_fare_outlined,
                  )
                : ListView(
                    padding: const EdgeInsets.all(22),
                    children: organizations
                        .map(
                          (o) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: BusinessCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    str(o['name']),
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    '${o['member_count'] ?? 0} 位成员 · 版本 ${o['revision']}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: mutedColor,
                                    ),
                                  ),
                                  if (str(o['description']).isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        str(o['description']),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          height: 1.8,
                                        ),
                                      ),
                                    ),
                                  if (e.can('manage_organizations'))
                                    Wrap(
                                      spacing: 10,
                                      children: [
                                        TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => _edit(o),
                                          child: const Text('编辑组织'),
                                        ),
                                        TextButton(
                                          onPressed:
                                              _busy ||
                                                  (o['member_count'] as num? ??
                                                          0) >
                                                      0
                                              ? null
                                              : () => _delete(o),
                                          child: const Text('删除空组织'),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      );
    },
  );
}

class _OrganizationForm extends StatefulWidget {
  const _OrganizationForm({required this.controller, this.organization});
  final EnterpriseState controller;
  final Json? organization;
  @override
  State<_OrganizationForm> createState() => _OrganizationFormState();
}

class _OrganizationFormState extends State<_OrganizationForm> {
  late Json? _organization = widget.organization;
  late final _name = TextEditingController(
    text: str(widget.organization?['name']),
  );
  late final _description = TextEditingController(
    text: str(widget.organization?['description']),
  );
  final _clientId = OfficeState.newClientId();
  String? _error;
  bool _busy = false;
  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请填写组织名称');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.saveOrganization(
        organization: _organization,
        name: _name.text.trim(),
        description: _description.text.trim(),
        clientId: _clientId,
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
    title: Text(_organization == null ? '新建组织' : '编辑组织'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              maxLength: 100,
              decoration: const InputDecoration(labelText: '组织名称'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _description,
              maxLines: 3,
              maxLength: 1000,
              decoration: const InputDecoration(labelText: '组织说明'),
            ),
            BusinessError(_error),
            if (_error != null && _organization != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        try {
                          await widget.controller.loadOrganizations();
                          final latest = widget.controller.organizations
                              .where((o) => o['id'] == _organization!['id'])
                              .firstOrNull;
                          if (mounted) {
                            setState(() {
                              if (latest != null) _organization = latest;
                              _error = latest == null
                                  ? '该组织已不存在，请关闭窗口后刷新。'
                                  : '已读取最新版本并保留你的编辑，请核对后保存。';
                            });
                          }
                        } catch (error) {
                          if (mounted) {
                            setState(() => _error = friendlyError(error));
                          }
                        }
                      },
                child: const Text('读取最新版本并保留编辑'),
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
        child: Text(_busy ? '正在保存…' : '保存组织'),
      ),
    ],
  );
}
