import 'package:flutter/material.dart';

import 'office_theme.dart';
import 'settings_session.dart';

class OfficeSettingsSection extends StatelessWidget {
  const OfficeSettingsSection({
    super.key,
    this.title,
    required this.children,
    this.mobile = false,
  });
  final String? title;
  final List<Widget> children;
  final bool mobile;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: mobile ? 16 : 26),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(
              title!,
              style: TextStyle(
                fontSize: mobile ? 12 : 14,
                fontWeight: mobile ? FontWeight.normal : FontWeight.w600,
                color: mobile ? mutedColor : inkColor,
              ),
            ),
          ),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(mobile ? 10 : 0),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: mobile ? 0.5 : 1,
                    thickness: mobile ? 0.5 : null,
                    color: mobile ? const Color(0xfff0f0f0) : null,
                    indent: 16,
                    endIndent: mobile ? 0 : 16,
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class OfficeSettingsRow extends StatelessWidget {
  const OfficeSettingsRow({
    super.key,
    required this.title,
    this.description,
    this.value,
    this.onTap,
    this.icon,
    this.unavailable = false,
  });
  final String title;
  final String? description, value;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool unavailable;
  @override
  Widget build(BuildContext context) => ListTile(
    minTileHeight: MediaQuery.sizeOf(context).width < 760 ? 52 : null,
    minVerticalPadding: MediaQuery.sizeOf(context).width < 760 ? 0 : null,
    contentPadding: EdgeInsets.symmetric(
      horizontal: 16,
      vertical: MediaQuery.sizeOf(context).width < 760 ? 0 : 3,
    ),
    leading: icon == null ? null : Icon(icon, size: 20, color: mutedColor),
    title: Text(
      title,
      style: TextStyle(
        fontSize: officeFontSize(
          context,
          desktop: 14,
          mobile: OfficeMobileType.title,
        ),
      ),
    ),
    subtitle: description == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              description!,
              style: TextStyle(
                fontSize: officeFontSize(
                  context,
                  desktop: 11,
                  mobile: OfficeMobileType.secondary,
                ),
                height: 1.6,
                color: mutedColor,
              ),
            ),
          ),
    trailing: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 150),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            Flexible(
              child: Text(
                value!,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: officeFontSize(
                    context,
                    desktop: 12,
                    mobile: OfficeMobileType.secondary,
                  ),
                  color: unavailable ? mutedColor : const Color(0xff646a73),
                ),
              ),
            ),
          if (onTap != null) ...[
            const SizedBox(width: 5),
            Icon(
              unavailable ? Icons.info_outline : Icons.chevron_right,
              size: 17,
              color: mutedColor,
            ),
          ],
        ],
      ),
    ),
    onTap: onTap,
  );
}

void showOfficeSettingStatus(
  BuildContext context,
  String title,
  String description,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Text(description, style: const TextStyle(height: 1.8)),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('知道了'),
      ),
    ],
  ),
);

class OfficeSettingsFeedback extends StatelessWidget {
  const OfficeSettingsFeedback({super.key, required this.session});
  final OfficeSettingsSession session;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (!session.state.connected)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '暂时离线，设置已保留；重新连接后可继续保存。',
            style: TextStyle(fontSize: 12, color: mutedColor),
          ),
        ),
      if (session.busy) const LinearProgressIndicator(minHeight: 2),
      if (session.error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            session.error!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ),
      if (session.conflict) ...[
        const Text(
          '设置已在另一端更新，本次更改尚未保存。读取最新设置后可重新选择。',
          style: TextStyle(fontSize: 12),
        ),
        TextButton(
          onPressed: session.busy ? null : session.readLatest,
          child: const Text('读取最新设置'),
        ),
        if (session.latest != null) ...[
          Text(
            '最新设置：${session.latest!['message_alignment'] == 'left' ? '消息气泡左对齐' : '消息气泡左右分布'} · 字体 ${(((session.latest!['text_scale'] as num?)?.toDouble() ?? 1) * 100).round()}% · ${session.latest!['time_format'] == '12h' ? '12' : '24'} 小时制',
            style: const TextStyle(fontSize: 11, height: 1.7),
          ),
          TextButton(
            onPressed: session.busy ? null : session.adoptLatest,
            child: const Text('采用最新设置，重新选择'),
          ),
        ],
      ],
    ],
  );
}

class OfficeConversationLayoutPreview extends StatelessWidget {
  const OfficeConversationLayoutPreview({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth < 450
          ? constraints.maxWidth
          : (constraints.maxWidth - 16) / 2;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final layout in ['left', 'split'])
            SizedBox(
              width: width,
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: value == layout ? accentColor : borderColor,
                    width: value == layout ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: enabled ? () => onChanged(layout) : null,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        _bubble(false, false),
                        const SizedBox(height: 12),
                        _bubble(true, layout == 'split'),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Icon(
                              value == layout
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              size: 18,
                              color: value == layout ? accentColor : mutedColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                layout == 'left' ? '消息气泡左对齐' : '消息气泡左右分布',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _bubble(bool own, bool right) => Row(
    mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
    children: [
      if (!right) ...[
        PersonAvatar(name: own ? '我' : 'Agent 同事', agent: !own, size: 25),
        const SizedBox(width: 7),
      ],
      Flexible(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: own ? selectedColor : const Color(0xfff2f3f5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            own ? '收到，我们一起推进。' : '共同文档已经更新。',
            style: const TextStyle(fontSize: 11, height: 1.6),
          ),
        ),
      ),
      if (right) ...[
        const SizedBox(width: 7),
        const PersonAvatar(name: '我', size: 25),
      ],
    ],
  );
}

class OfficeFontSizePreview extends StatelessWidget {
  const OfficeFontSizePreview({
    super.key,
    required this.scale,
    required this.enabled,
    required this.onChanged,
  });
  final double scale;
  final bool enabled;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Material(
        color: const Color(0xfff7f9fc),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '一起把工作做好',
                textScaler: TextScaler.linear(scale),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '人与 Agent 在共同文档里读懂上下文，一起推进工作。\n预览时间：09:41',
                textScaler: TextScaler.linear(scale),
                style: TextStyle(
                  fontSize: officeFontSize(
                    context,
                    desktop: 14,
                    mobile: OfficeMobileType.body,
                  ),
                  height: MediaQuery.sizeOf(context).width < 760 ? 1.5 : 1.9,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final option in [0.85, 1.0, 1.15, 1.3])
            ChoiceChip(
              label: Text('${(option * 100).round()}%'),
              selected: scale == option,
              showCheckmark: false,
              onSelected: enabled ? (_) => onChanged(option) : null,
            ),
        ],
      ),
      const SizedBox(height: 10),
      const Text(
        '调整整个办公界面的文字比例，预览随设置变化。',
        style: TextStyle(fontSize: 11, color: mutedColor),
      ),
    ],
  );
}

class OfficeAppearancePreview extends StatelessWidget {
  const OfficeAppearancePreview({super.key, this.desktop = false});
  final bool desktop;
  @override
  Widget build(BuildContext context) => desktop
      ? _desktop()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '当前外观：浅色',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [
                for (final dark in [false, true])
                  SizedBox(
                    width: 140,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 94,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: dark
                                ? const Color(0xff252a34)
                                : const Color(0xfff4f6fa),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: dark ? borderColor : accentColor,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 60,
                                height: 7,
                                color: dark
                                    ? Colors.white54
                                    : const Color(0xffccd2de),
                              ),
                              const SizedBox(height: 14),
                              Container(
                                width: 96,
                                height: 19,
                                decoration: BoxDecoration(
                                  color: dark
                                      ? const Color(0xff3d4350)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  width: 70,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: accentColor,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          dark ? '深色预览 · 尚未接入' : '浅色 · 当前使用',
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
            const SizedBox(height: 16),
            const Text(
              '深色模式、跟随系统和自定义主题色尚未接入；当前使用浅色界面与人机蓝色。',
              style: TextStyle(fontSize: 12, color: mutedColor, height: 1.7),
            ),
          ],
        );

  Widget _desktop() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Tooltip(
        message: '跟随系统尚未接入，当前界面使用浅色。',
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(value: false, onChanged: null),
            ),
            SizedBox(width: 7),
            Text('跟随系统', style: TextStyle(fontSize: 14)),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(left: 25, top: 4, bottom: 14),
        child: Text(
          '主题自动切换尚未接入；当前使用浅色界面。',
          style: TextStyle(fontSize: 12, color: mutedColor),
        ),
      ),
      LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth < 504
              ? ((constraints.maxWidth - 24) / 2).clamp(140.0, 240.0)
              : 240.0;
          return Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              for (final dark in [false, true])
                Semantics(
                  label: dark ? '深色模式尚未接入' : '当前使用浅色模式',
                  child: Container(
                    width: width,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      children: [
                        Container(
                          height: 82,
                          padding: const EdgeInsets.all(14),
                          color: dark ? const Color(0xff171717) : Colors.white,
                          child: Column(
                            children: [
                              for (var row = 0; row < 2; row++) ...[
                                if (row > 0) const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: dark
                                            ? const Color(0xff555555)
                                            : const Color(0xffeff0f1),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: FractionallySizedBox(
                                          widthFactor: row == 0 ? 1 : .62,
                                          child: Container(
                                            height: 21,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                              color: row == 0
                                                  ? (dark
                                                        ? const Color(
                                                            0xff494949,
                                                          )
                                                        : const Color(
                                                            0xffeff0f1,
                                                          ))
                                                  : (dark
                                                        ? const Color(
                                                            0xff2b61bb,
                                                          )
                                                        : const Color(
                                                            0xffd1e3ff,
                                                          )),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 9,
                          ),
                          color: dark ? Colors.white : const Color(0xfff0f4ff),
                          child: Row(
                            children: [
                              Icon(
                                dark
                                    ? Icons.radio_button_off
                                    : Icons.radio_button_checked,
                                size: 18,
                                color: dark ? mutedColor : accentColor,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  dark ? '深色预览 · 尚未接入' : '浅色 · 当前使用',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );
}
