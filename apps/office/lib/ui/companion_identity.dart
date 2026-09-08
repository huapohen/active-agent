import 'package:flutter/material.dart';

import 'office_theme.dart';

bool isOfficeCompanion(Json person) => person['device_capabilities'] is Map;

/// The cursor identifies a device companion. It does not indicate a connected
/// runtime or a live device operation.
class CompanionAvatar extends StatelessWidget {
  const CompanionAvatar({super.key, required this.person, this.size = 42});
  final Json person;
  final double size;

  @override
  Widget build(BuildContext context) {
    final capabilities = person['device_capabilities'] as Map? ?? {};
    final mobile = maps(capabilities['supported_modes'])
        .any((mode) => mode['id'] == 'isolated_android_device');
    return Semantics(
      label: mobile ? '手机机伴' : '电脑机伴',
      child: ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xffe9e4ff), Color(0xffdcecff)],
            ),
            shape: BoxShape.circle,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                mobile ? Icons.smartphone_rounded : Icons.desktop_mac_rounded,
                size: size * .55,
                color: const Color(0xff7263b9),
              ),
              Positioned(
                right: 1,
                bottom: 0,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 650),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) => Transform.translate(
                    offset: Offset(5 * (1 - value), 7 * (1 - value)),
                    child: child,
                  ),
                  child: Icon(
                    Icons.near_me_rounded,
                    size: size * .42,
                    color: const Color(0xff426ad9),
                    shadows: const [Shadow(color: Colors.white, blurRadius: 3)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CompanionCapabilities extends StatelessWidget {
  const CompanionCapabilities({super.key, required this.person});
  final Json person;

  @override
  Widget build(BuildContext context) {
    if (!isOfficeCompanion(person)) return const SizedBox.shrink();
    final capabilities = person['device_capabilities'] as Map;
    final supported = maps(capabilities['supported_modes']);
    final unsupported = maps(capabilities['unsupported_modes']);
    final requirements = (capabilities['runtime_requirements'] as List? ?? [])
        .map(str)
        .where((value) => value.isNotEmpty);
    Widget line(IconData icon, String title, String description) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xff796ca7)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: officeFontSize(context, desktop: 11, mobile: 14),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (description.isNotEmpty)
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: officeFontSize(
                        context,
                        desktop: 11,
                        mobile: 14,
                      ),
                      height: 1.7,
                      color: mutedColor,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfff5f3fc),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '机伴运行范围',
            style: TextStyle(
              fontSize: officeFontSize(context, desktop: 12, mobile: 17),
              fontWeight: FontWeight.w600,
            ),
          ),
          if (capabilities['installation_grants_device_access'] == false)
            Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '添加好友后可开始办公协作。设备操作需要另行连接运行环境并获得授权。',
                style: TextStyle(
                  fontSize: officeFontSize(context, desktop: 11, mobile: 14),
                  height: 1.7,
                  color: mutedColor,
                ),
              ),
            ),
          for (final mode in supported)
            line(
              Icons.layers_outlined,
              '${str(mode['label'])}${switch (mode['status']) {
                'runtime_required' => ' · 需接入运行环境',
                'member_permissions_required' => ' · 按成员权限',
                _ => '',
              }}',
              str(mode['description']),
            ),
          for (final mode in unsupported)
            line(Icons.info_outline, str(mode['label']), str(mode['reason'])),
          if (requirements.isNotEmpty)
            Material(
              color: Colors.transparent,
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  '查看接入要求',
                  style: TextStyle(
                    fontSize: officeFontSize(context, desktop: 11, mobile: 14),
                    color: accentColor,
                  ),
                ),
                children: [
                  for (final requirement in requirements)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          requirement,
                          style: TextStyle(
                            fontSize: officeFontSize(
                              context,
                              desktop: 11,
                              mobile: 14,
                            ),
                            height: 1.7,
                            color: mutedColor,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
