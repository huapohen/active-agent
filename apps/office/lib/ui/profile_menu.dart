import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'office_theme.dart';
import 'professional_identity.dart';

Future<String?> showOfficeProfileMenu(
  BuildContext context,
  OfficeState state, {
  required Rect anchor,
}) => showDialog<String>(
  context: context,
  useSafeArea: false,
  barrierColor: Colors.black26,
  builder: (context) {
    final size = MediaQuery.sizeOf(context);
    final mobile = size.width < 760;
    final panel = Material(
      color: Colors.white,
      elevation: 12,
      borderRadius: BorderRadius.circular(mobile ? 0 : 12),
      child: OfficeProfilePanel(state: state),
    );
    if (mobile) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: math.min(size.width * .875, 390),
          height: double.infinity,
          child: panel,
        ),
      );
    }
    return Stack(
      children: [
        Positioned(
          left: anchor.left.clamp(12, math.max(12, size.width - 350)),
          top: math.min(anchor.bottom + 8, 100),
          width: 326,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height - 125),
            child: panel,
          ),
        ),
      ],
    );
  },
);

class OfficeProfilePanel extends StatefulWidget {
  const OfficeProfilePanel({super.key, required this.state});
  final OfficeState state;
  @override
  State<OfficeProfilePanel> createState() => _OfficeProfilePanelState();
}

class _OfficeProfilePanelState extends State<OfficeProfilePanel> {
  OfficeState get state => widget.state;
  late final OfficeState _stateAtOpen;
  late final String _endpoint;
  late final String _principalId;
  late final int _generation;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _stateAtOpen = state;
    _endpoint = state.endpoint;
    _principalId = personId(state.me ?? {});
    _generation = state.identityGeneration;
    state.addListener(_changed);
  }

  bool get _currentIdentity =>
      !_expired &&
      identical(state, _stateAtOpen) &&
      state.endpoint == _endpoint &&
      personId(state.me ?? {}) == _principalId &&
      state.identityGeneration == _generation;

  void _open(String action) {
    if (!mounted || !_currentIdentity) return;
    if (action == 'enterprise' && !state.canManageEnterprise) return;
    Navigator.pop(context, action);
  }

  @override
  void didUpdateWidget(covariant OfficeProfilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, state)) {
      oldWidget.state.removeListener(_changed);
      state.addListener(_changed);
      _expired = true;
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      _expired = !_currentIdentity;
    });
  }

  @override
  void dispose() {
    state.removeListener(_changed);
    super.dispose();
  }

  String _roleLabel(dynamic value) =>
      const {'owner': '企业所有者', 'admin': '企业管理员', 'member': '普通成员'}[value] ??
      str(value);

  String _statusLabel(dynamic value) =>
      const {'active': '正常', 'disabled': '已停用', 'revoked': '已撤销'}[value] ??
      str(value);

  @override
  Widget build(BuildContext context) {
    if (!_currentIdentity) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('工作身份已切换'),
              const SizedBox(height: 12),
              const Text('请重新打开“我的”查看当前身份。'),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    }
    final membership = state.enterpriseSummary['membership'] as Map? ?? {};
    final enterprise = state.enterpriseSummary['enterprise'] as Map? ?? {};
    final identity = <String, dynamic>{...membership, ...?state.me};
    final organization = str(
      identity['organization_name'],
      str(enterprise['name']),
    );
    final role = _roleLabel(membership['role']);
    final status = _statusLabel(membership['status']);
    if (MediaQuery.sizeOf(context).width < 760) {
      return _mobile(identity, organization, role, status);
    }
    Widget action(String label, IconData icon, String value) => ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: mutedColor),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      trailing: const Icon(Icons.chevron_right, size: 18, color: mutedColor),
      onTap: () => _open(value),
    );
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '我的',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭我的面板',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PersonAvatar(
                    name: str(identity['name']),
                    agent: identity['kind'] == 'agent',
                    size: 52,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          str(identity['name']),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IdentityBadge(agent: identity['kind'] == 'agent'),
                    ],
                  ),
                  if (organization.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        organization,
                        style: const TextStyle(fontSize: 12, color: mutedColor),
                      ),
                    ),
                  if (role.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        '$role${status.isEmpty ? '' : ' · $status'}',
                        style: const TextStyle(fontSize: 12, color: mutedColor),
                      ),
                    ),
                  if (str(state.accountInfo['username']).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        '账号：${state.accountInfo['username']}',
                        style: const TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    ),
                  ProfessionalIdentity(
                    person: {...identity}..remove('organization_name'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      if (!_currentIdentity) return;
                      await Clipboard.setData(
                        ClipboardData(text: _principalId),
                      );
                      if (context.mounted && _currentIdentity) {
                        notifyOffice(context, '当前身份 ID 已复制');
                      }
                    },
                    icon: const Icon(Icons.copy_outlined, size: 14),
                    label: const Text(
                      '复制身份 ID',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 18),
            action('我的账号与设备', Icons.manage_accounts_outlined, 'account'),
            action('设置', Icons.settings_outlined, 'settings'),
            action('工作台', Icons.grid_view_rounded, 'workbench'),
            if (state.canManageEnterprise)
              action('企业管理', Icons.apartment_outlined, 'enterprise'),
            const Divider(height: 18),
            action('退出当前身份', Icons.logout, 'logout'),
          ],
        ),
      ),
    );
  }

  Widget _mobile(
    Json identity,
    String organization,
    String role,
    String status,
  ) {
    final name = str(identity['name']);
    Widget row(
      String title,
      IconData icon,
      Color color,
      String action, {
      String? detail,
      bool enabled = true,
    }) => InkWell(
      onTap: enabled ? () => _open(action) : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 57),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 22, color: enabled ? color : mutedColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    height: 1.3,
                    color: enabled ? inkColor : mutedColor,
                  ),
                ),
              ),
              if (detail != null)
                Text(
                  detail,
                  style: const TextStyle(fontSize: 12, color: mutedColor),
                ),
            ],
          ),
        ),
      ),
    );
    return Row(
      key: const ValueKey('mobile-profile-layout'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('mobile-profile-account-rail'),
          width: 98,
          child: ColoredBox(
            color: const Color(0xfff5f6f7),
            child: SafeArea(
              right: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(9, 24, 9, 16),
                child: Column(
                  children: [
                    Semantics(
                      selected: true,
                      label: '当前工作空间：$organization',
                      child: InkWell(
                        onTap: () => _open('workspace'),
                        child: Column(
                          children: [
                            Container(
                              width: 50,
                              height: 50,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: accentColor,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                initial(
                                  organization.isEmpty ? '人机' : organization,
                                ),
                                style: const TextStyle(
                                  fontSize: 25,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              organization.isEmpty ? '当前工作空间' : organization,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 11,
                                color: mutedColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    InkWell(
                      onTap: () => _open('switch'),
                      child: Column(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: const Icon(
                              Icons.add,
                              size: 32,
                              color: mutedColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '登录更多账号',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: inkColor),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: SafeArea(
            left: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () => _open('card'),
                        child: PersonAvatar(
                          key: const ValueKey('mobile-profile-avatar'),
                          name: name,
                          agent: identity['kind'] == 'agent',
                          size: 70,
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topRight,
                          child: OutlinedButton(
                            onPressed: () => _open('status'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: const Size(58, 30),
                              side: const BorderSide(color: accentColor),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            child: const Text(
                              '+ 状态',
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: () => _open('card'),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 2,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          size: 22,
                          color: mutedColor,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    organization.isEmpty ? '当前工作空间' : organization,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: mutedColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => _open('card'),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xfff5f6f7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        role.isEmpty
                            ? '查看我的工作身份…'
                            : '$role${status.isEmpty ? '' : ' · $status'}',
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: mutedColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  row('我的个人名片', Icons.person_outline, accentColor, 'card'),
                  row(
                    '钱包',
                    Icons.account_balance_wallet_outlined,
                    const Color(0xfff54a45),
                    'wallet',
                    detail: '未接入',
                    enabled: false,
                  ),
                  row(
                    '收藏',
                    Icons.star_border,
                    const Color(0xfff5b400),
                    'favorites',
                  ),
                  row(
                    '登录更多账号',
                    Icons.group_add_outlined,
                    accentColor,
                    'switch',
                  ),
                  row(
                    '帮助与客服',
                    Icons.headset_mic_outlined,
                    const Color(0xfff54a45),
                    'help',
                  ),
                  row(
                    'Agent 同事',
                    Icons.auto_awesome_outlined,
                    accentColor,
                    'agents',
                  ),
                  row(
                    '登录设备',
                    Icons.phone_iphone_outlined,
                    const Color(0xff2db5d9),
                    'account',
                  ),
                  row('设置', Icons.settings_outlined, accentColor, 'settings'),
                  if (state.canManageEnterprise)
                    row(
                      '企业管理',
                      Icons.apartment_outlined,
                      accentColor,
                      'enterprise',
                    ),
                  row('退出当前身份', Icons.logout, mutedColor, 'logout'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
