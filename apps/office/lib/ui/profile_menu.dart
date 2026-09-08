import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_theme.dart';

Future<String?> showOfficeProfileMenu(
  BuildContext context,
  OfficeState state, {
  required Rect anchor,
}) => showDialog<String>(
  context: context,
  useSafeArea: false,
  barrierColor: MediaQuery.sizeOf(context).width < 760
      ? Colors.black26
      : Colors.transparent,
  builder: (context) {
    final size = MediaQuery.sizeOf(context);
    final mobile = size.width < 760;
    final panel = Material(
      color: Colors.white,
      elevation: 6,
      borderRadius: BorderRadius.circular(mobile ? 0 : 8),
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
          left: anchor.right.clamp(12, math.max(12, size.width - 332)),
          top: anchor.top.clamp(12, math.max(12, size.height - 200)),
          width: 318,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(120, size.height - anchor.top - 12),
            ),
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
    Widget action(String label, String value, {IconData? trailing}) => InkWell(
      onTap: () => _open(value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 38),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 14, height: 1.3),
                ),
              ),
              if (trailing != null) Icon(trailing, size: 16, color: mutedColor),
            ],
          ),
        ),
      ),
    );
    return SingleChildScrollView(
      key: const ValueKey('desktop-profile-layout'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => _open('card'),
                    child: PersonAvatar(
                      name: str(identity['name']),
                      agent: identity['kind'] == 'agent',
                      size: 56,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => _open('card'),
                          child: Text(
                            str(identity['name']),
                            style: const TextStyle(
                              fontSize: 18,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (organization.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Tooltip(
                              message: organization,
                              child: Text(
                                organization,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: mutedColor,
                                ),
                              ),
                            ),
                          ),
                        if (str(state.accountInfo['username']).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              '账号：${state.accountInfo['username']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: mutedColor,
                              ),
                            ),
                          ),
                        const SizedBox(height: 6),
                        OutlinedButton(
                          onPressed: () => _open('status'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(54, 24),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            side: const BorderSide(color: accentColor),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          child: const Text(
                            '+ 状态',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: InkWell(
                onTap: () => _open('card'),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xfff5f6f7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    role.isEmpty
                        ? '查看我的工作身份'
                        : '$role${status.isEmpty ? '' : ' · $status'}',
                    style: const TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            action('我的个人名片', 'card'),
            action('我的账号与设备', 'account'),
            action('登录更多账号', 'switch'),
            const Divider(height: 18, indent: 20, endIndent: 20),
            action('帮助与客服', 'help', trailing: Icons.open_in_new),
            action('Agent 同事', 'agents', trailing: Icons.auto_awesome),
            action('设置', 'settings'),
            action('工作台', 'workbench'),
            if (state.canManageEnterprise) action('企业管理', 'enterprise'),
            action('退出当前身份', 'logout'),
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
