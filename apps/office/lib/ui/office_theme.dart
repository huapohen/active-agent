import 'package:flutter/material.dart';

const shellColor = Color(0xffedf1fa);
const accentColor = Color(0xff3370ff);
const inkColor = Color(0xff1f2329);
const mutedColor = Color(0xff8f959e);
const borderColor = Color(0xffeff0f1);
const selectedColor = Color(0xffe8eeff);

typedef Json = Map<String, dynamic>;

/// Native mobile baselines at 100%; user accessibility scaling applies on top.
abstract final class OfficeMobileType {
  static const double title = 17;
  static const double body = 17;
  static const double secondary = 14;
  static const double caption = 12;
  static const double tab = 14;
  static const double navigation = 11;
}

double officeFontSize(
  BuildContext context, {
  required double desktop,
  required double mobile,
}) => MediaQuery.sizeOf(context).width < 760 ? mobile : desktop;

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 44});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .24),
    child: Image.asset(
      'assets/branding/rocket.png',
      width: size,
      height: size,
      semanticLabel: '人机火箭标志',
    ),
  );
}

ThemeData officeTheme() => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: shellColor,
  colorScheme: ColorScheme.fromSeed(seedColor: accentColor),
  fontFamilyFallback: const [
    'PingFang SC',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
  ],
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 13, color: inkColor, height: 1.55),
    bodySmall: TextStyle(fontSize: 11, color: mutedColor),
    titleMedium: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: inkColor,
    ),
  ),
  dividerColor: borderColor,
  inputDecorationTheme: InputDecorationTheme(
    isDense: true,
    filled: true,
    fillColor: const Color(0xfff5f6f7),
    contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
    hintStyle: const TextStyle(color: Color(0xffb2b6bd), fontSize: 13),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(7),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(7),
      borderSide: const BorderSide(color: accentColor),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: accentColor,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: accentColor,
      textStyle: const TextStyle(fontSize: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(
      foregroundColor: const Color(0xff646a73),
      iconSize: 19,
      minimumSize: const Size(32, 32),
      padding: const EdgeInsets.all(7),
    ),
  ),
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: const Color(0xff2b2f36),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
  ),
);

String str(dynamic value, [String fallback = '']) =>
    value == null ? fallback : value.toString();
List<Json> maps(dynamic value) => value is List
    ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : [];
String personId(Json person) => str(person['principal_id'] ?? person['id']);

/// Room display names never replace the stable principal ID or legal name.
String officeDisplayName(Json person) {
  for (final key in ['display_name', 'nickname', 'name']) {
    final value = str(person[key]);
    if (value.trim().isNotEmpty) return value;
  }
  return '工作成员';
}

String initial(String name) =>
    name.characters.isEmpty ? '同' : name.characters.first;
String officeHourMinute(DateTime time, {BuildContext? context}) {
  final use24Hours =
      context == null ||
      MediaQuery.maybeOf(context)?.alwaysUse24HourFormat != false;
  final minute = time.minute.toString().padLeft(2, '0');
  if (use24Hours) return '${time.hour.toString().padLeft(2, '0')}:$minute';
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  return '${time.hour < 12 ? '上午' : '下午'} $hour:$minute';
}

String clockText(dynamic value, {bool date = false, BuildContext? context}) {
  final time = DateTime.tryParse(str(value))?.toLocal();
  if (time == null) return '';
  final now = DateTime.now();
  final today =
      time.year == now.year && time.month == now.month && time.day == now.day;
  final hhmm = officeHourMinute(time, context: context);
  if (!date && today) return hhmm;
  return '${time.month}/${time.day}${date ? ' $hhmm' : ''}';
}

String statusName(dynamic value) =>
    const {
      'open': '待办',
      'doing': '进行中',
      'done': '已完成',
      'active': '主动参与',
      'mentions': '提及时参与',
      'paused': '已暂停',
      'running': '正在推进',
      'replied': '已交付',
      'silent': '保持观察',
      'blocked': '需要补充',
      'stale': '上下文已更新',
      'cancelled': '已取消',
      'failed': '需要关注',
    }[value] ??
    str(value);

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.agent = false,
    this.size = 36,
    this.group = false,
  });
  final String name;
  final bool agent, group;
  final double size;
  @override
  Widget build(BuildContext context) {
    final palette = [
      const Color(0xff5b8ff9),
      const Color(0xff8e7cd1),
      const Color(0xffe0a465),
      const Color(0xff6ea7a7),
      const Color(0xff7c9ac4),
    ];
    final hash = name.runes.fold<int>(0, (a, b) => a + b);
    final color = agent
        ? const Color(0xff7484cb)
        : palette[hash % palette.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: group
          ? Icon(Icons.forum_rounded, color: Colors.white, size: size * .51)
          : agent
          ? Icon(
              Icons.auto_awesome_rounded,
              color: Colors.white,
              size: size * .5,
            )
          : Text(
              initial(name),
              style: TextStyle(
                color: Colors.white,
                fontSize: size * .4,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }
}

class IdentityBadge extends StatelessWidget {
  const IdentityBadge({super.key, required this.agent});
  final bool agent;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      color: agent ? const Color(0xffeef0ff) : const Color(0xfff2f3f5),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      agent ? 'Agent' : '成员',
      style: TextStyle(
        fontSize: 9,
        height: 1.4,
        color: agent ? const Color(0xff7782bc) : mutedColor,
      ),
    ),
  );
}

class EmptyOffice extends StatelessWidget {
  const EmptyOffice({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.forum_outlined,
    this.action,
  });
  final String title, subtitle;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: const Color(0xfff0f4ff),
              borderRadius: BorderRadius.circular(23),
            ),
            child: Icon(icon, size: 34, color: const Color(0xff9caee0)),
          ),
          const SizedBox(height: 23),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: mutedColor,
              fontSize: 12,
              height: 1.9,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 23), action!],
        ],
      ),
    ),
  );
}

class OfficeSearch extends StatelessWidget {
  const OfficeSearch({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
    this.onTap,
    this.readOnly = false,
  });
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  final VoidCallback? onTap;
  final bool readOnly;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: officeFontSize(context, desktop: 33, mobile: 36),
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      onTap: onTap,
      readOnly: readOnly,
      canRequestFocus: !readOnly,
      showCursor: readOnly ? false : null,
      enableInteractiveSelection: !readOnly,
      style: TextStyle(
        fontSize: officeFontSize(context, desktop: 12, mobile: 16),
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: officeFontSize(context, desktop: 12, mobile: 16),
          color: const Color(0xffa4a9b2),
        ),
        prefixIcon: const Icon(Icons.search, size: 17),
        prefixIconConstraints: const BoxConstraints(minWidth: 33),
        contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      ),
    ),
  );
}

void notifyOffice(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
  );
}
