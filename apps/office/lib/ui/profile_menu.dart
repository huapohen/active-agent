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
          width: math.min(size.width * .86, 350),
          height: double.infinity,
          child: SafeArea(child: panel),
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

class OfficeProfilePanel extends StatelessWidget {
  const OfficeProfilePanel({super.key, required this.state});
  final OfficeState state;
  @override
  Widget build(BuildContext context) {
    final membership = state.enterpriseSummary['membership'] as Map? ?? {};
    final enterprise = state.enterpriseSummary['enterprise'] as Map? ?? {};
    final identity = <String, dynamic>{...membership, ...?state.me};
    final organization = str(
      identity['organization_name'],
      str(enterprise['name']),
    );
    Widget action(String label, IconData icon, String value) => ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: mutedColor),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      trailing: const Icon(Icons.chevron_right, size: 18, color: mutedColor),
      onTap: () => Navigator.pop(context, value),
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
                      await Clipboard.setData(
                        ClipboardData(text: personId(state.me ?? {})),
                      );
                      if (context.mounted) notifyOffice(context, '当前身份 ID 已复制');
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
            action('个人设置', Icons.settings_outlined, 'settings'),
            action('工作台', Icons.grid_view_rounded, 'workbench'),
            action('编辑手机底栏', Icons.view_carousel_outlined, 'navigation'),
            if (state.canManageEnterprise)
              action('企业管理', Icons.apartment_outlined, 'enterprise'),
            const Divider(height: 18),
            action('退出当前身份', Icons.logout, 'logout'),
          ],
        ),
      ),
    );
  }
}
