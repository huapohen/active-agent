import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'office_theme.dart';

typedef CalendarJson = Map<String, dynamic>;

bool _zonesReady = false;
void _initializeZones() {
  if (_zonesReady) return;
  tzdata.initializeTimeZones();
  _zonesReady = true;
}

const calendarTimezones = <String, String>{
  'Asia/Shanghai': '中国标准时间',
  'UTC': '协调世界时',
  'Asia/Tokyo': '日本标准时间',
  'Asia/Singapore': '新加坡时间',
  'Europe/London': '伦敦时间',
  'Europe/Berlin': '柏林时间',
  'America/New_York': '纽约时间',
  'America/Los_Angeles': '洛杉矶时间',
  'Australia/Sydney': '悉尼时间',
};
DateTime calendarWallTime(DateTime instant, String timezone) {
  _initializeZones();
  final value = tz.TZDateTime.from(instant, tz.getLocation(timezone));
  return DateTime(
    value.year,
    value.month,
    value.day,
    value.hour,
    value.minute,
    value.second,
    value.millisecond,
    value.microsecond,
  );
}

DateTime calendarInstant(DateTime wall, String timezone) {
  _initializeZones();
  final location = tz.getLocation(timezone);
  final wallUtc = DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  );
  DateTime? earliest;
  // Try the real offsets in this IANA location and round-trip each candidate.
  // This handles fractional offsets, gaps and overlaps without guessed windows.
  for (final offset in location.zones.map((zone) => zone.offset).toSet()) {
    final candidate = wallUtc.subtract(offset);
    final local = tz.TZDateTime.from(candidate, location);
    if (local.year == wall.year &&
        local.month == wall.month &&
        local.day == wall.day &&
        local.hour == wall.hour &&
        local.minute == wall.minute &&
        local.second == wall.second &&
        local.millisecond == wall.millisecond &&
        local.microsecond == wall.microsecond &&
        (earliest == null || candidate.isBefore(earliest))) {
      earliest = candidate;
    }
  }
  if (earliest == null) {
    throw const FormatException('所选时刻在该时区不存在，请调整夏令时切换附近的时间。');
  }
  return earliest;
}

int calendarPickerMinYear(DateTime value) =>
    value.year < 2020 ? value.year : 2020;
int calendarPickerMaxYear(DateTime value) =>
    value.year > 2040 ? value.year : 2040;
String calendarDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime calendarDay(DateTime d, [int delta = 0]) =>
    DateTime(d.year, d.month, d.day + delta);
String calendarDateLabel(DateTime d) => '${d.year}年${d.month}月${d.day}日';
DateTime? calendarParseDate(dynamic value) =>
    value is String ? DateTime.tryParse(value) : null;
String calendarAllDayLabel(CalendarJson event) {
  final start = calendarParseDate(event['start_date']);
  final end = calendarParseDate(event['end_date']);
  if (start == null || end == null) return '全天';
  final last = calendarDay(end, -1);
  return start == last
      ? '${calendarDateLabel(start)} · 全天'
      : '${calendarDateLabel(start)} – ${calendarDateLabel(last)} · 全天';
}

class CalendarDateWheel extends StatelessWidget {
  const CalendarDateWheel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => CupertinoTheme(
    data: CupertinoTheme.of(context).copyWith(
      textTheme: CupertinoTheme.of(context).textTheme.copyWith(
        dateTimePickerTextStyle: const TextStyle(fontSize: 18, color: inkColor),
      ),
    ),
    child: child,
  );
}

class CalendarSchedule {
  const CalendarSchedule({
    required this.start,
    required this.end,
    this.allDay = false,
    this.timezone = 'Asia/Shanghai',
  });
  final DateTime start, end;
  final bool allDay;
  final String timezone;
  // End is exclusive in both modes. UI renders the last included day for all-day.
  CalendarSchedule copyWith({
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? timezone,
  }) => CalendarSchedule(
    start: start ?? this.start,
    end: end ?? this.end,
    allDay: allDay ?? this.allDay,
    timezone: timezone ?? this.timezone,
  );
  CalendarJson toFields() => allDay
      ? {
          'all_day': true,
          'timezone': timezone,
          'start_date': calendarDate(start),
          'end_date': calendarDate(end),
        }
      : {
          'all_day': false,
          'timezone': timezone,
          'starts_at': calendarInstant(start, timezone).toIso8601String(),
          'ends_at': calendarInstant(end, timezone).toIso8601String(),
        };
}

Future<String?> chooseCalendarTimezone(
  BuildContext context, {
  required String current,
  required bool Function() valid,
  required Listenable identity,
}) => showDialog<String>(
  context: context,
  builder: (dialog) => AnimatedBuilder(
    animation: identity,
    builder: (_, _) => AlertDialog(
      backgroundColor: Colors.white,
      title: Text(valid() ? '时区' : '当前日程已过期'),
      content: valid()
          ? SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: calendarTimezones.entries
                      .map(
                        (entry) => ListTile(
                          title: Text(entry.value),
                          subtitle: Text(entry.key),
                          trailing: current == entry.key
                              ? const Icon(Icons.check, color: accentColor)
                              : null,
                          onTap: () {
                            if (valid()) Navigator.pop(dialog, entry.key);
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
            )
          : const Text('身份或日程权限已改变，请返回重新打开。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('取消'),
        ),
      ],
    ),
  ),
);

class _CalendarSubpageFocus {
  _CalendarSubpageFocus() : node = FocusManager.instance.primaryFocus {
    if (node != null) {
      allowed = node!.canRequestFocus;
      node!.unfocus();
      node!.canRequestFocus = false;
    }
  }
  final FocusNode? node;
  bool allowed = false;
  void restore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (node?.context != null) node!.canRequestFocus = allowed;
    });
  }
}

Future<CalendarSchedule?> showCalendarTimePage(
  BuildContext context, {
  required CalendarSchedule schedule,
  required bool Function() valid,
  required Listenable identity,
  bool beginning = true,
  bool allowAllDay = true,
}) async {
  final sourceFocus = _CalendarSubpageFocus();
  try {
    return await Navigator.of(
      context,
      rootNavigator: true,
    ).push<CalendarSchedule>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _CalendarTimePage(
          initial: schedule,
          valid: valid,
          identity: identity,
          beginning: beginning,
          allowAllDay: allowAllDay,
        ),
      ),
    );
  } finally {
    sourceFocus.restore();
  }
}

class _CalendarTimePage extends StatefulWidget {
  const _CalendarTimePage({
    required this.initial,
    required this.valid,
    required this.identity,
    required this.beginning,
    required this.allowAllDay,
  });
  final CalendarSchedule initial;
  final bool Function() valid;
  final Listenable identity;
  final bool beginning, allowAllDay;
  @override
  State<_CalendarTimePage> createState() => _CalendarTimePageState();
}

class _CalendarTimePageState extends State<_CalendarTimePage> {
  late CalendarSchedule value = widget.initial;
  late bool beginning = widget.beginning;
  String? error;
  DateTime get shownEnd =>
      value.allDay ? calendarDay(value.end, -1) : value.end;
  void select(DateTime date) => setState(() {
    var start = value.start, end = value.end;
    if (beginning) {
      start = value.allDay ? calendarDay(date) : date;
      if (!end.isAfter(start)) {
        end = value.allDay
            ? calendarDay(start, 1)
            : start.add(const Duration(hours: 1));
      }
    } else {
      end = value.allDay ? calendarDay(date, 1) : date;
    }
    value = value.copyWith(start: start, end: end);
    error = null;
  });
  Widget column(bool first) {
    final date = first ? value.start : shownEnd;
    return Expanded(
      child: InkWell(
        key: ValueKey(first ? 'calendar-time-start' : 'calendar-time-end'),
        onTap: () => setState(() => beginning = first),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value.allDay
                    ? '${date.month}月${date.day}日'
                    : officeHourMinute(date, context: context),
                style: TextStyle(
                  fontSize: 18,
                  color: first == beginning ? accentColor : inkColor,
                ),
              ),
              Text(
                '${value.allDay ? '' : '${date.month}月${date.day}日 '}周${['日', '一', '二', '三', '四', '五', '六'][date.weekday % 7]}',
                style: TextStyle(
                  fontSize: 14,
                  color: first == beginning ? accentColor : mutedColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.identity,
    builder: (_, _) {
      final valid = widget.valid();
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('时间', style: TextStyle(fontSize: 17)),
          centerTitle: true,
          leading: IconButton(
            tooltip: '返回日程',
            icon: const Icon(Icons.chevron_left, size: 28),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            TextButton(
              onPressed: !valid
                  ? null
                  : () {
                      if (!widget.valid()) return;
                      try {
                        if (!value.end.isAfter(value.start)) {
                          throw const FormatException('结束时间必须晚于开始时间');
                        }
                        value.toFields();
                        Navigator.pop(context, value);
                      } catch (e) {
                        setState(
                          () => error = e is FormatException
                              ? e.message
                              : '时间格式无效',
                        );
                      }
                    },
              child: const Text('完成', style: TextStyle(fontSize: 17)),
            ),
          ],
        ),
        body: !valid
            ? const Center(child: Text('身份或日程权限已改变，请返回重新打开。'))
            : SafeArea(
                top: false,
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    SwitchListTile(
                      key: const ValueKey('calendar-time-all-day'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('全天', style: TextStyle(fontSize: 17)),
                      value: value.allDay,
                      onChanged: !widget.allowAllDay
                          ? null
                          : (allDay) => setState(() {
                              value = value.copyWith(
                                allDay: allDay,
                                start: allDay
                                    ? calendarDay(value.start)
                                    : value.start.add(const Duration(hours: 9)),
                                end: allDay
                                    ? calendarDay(
                                        value.end,
                                        value.end.hour == 0 &&
                                                value.end.minute == 0
                                            ? 0
                                            : 1,
                                      )
                                    : calendarDay(
                                        value.end,
                                        -1,
                                      ).add(const Duration(hours: 10)),
                              );
                              if (!value.end.isAfter(value.start)) {
                                value = value.copyWith(
                                  end: allDay
                                      ? calendarDay(value.start, 1)
                                      : value.start.add(
                                          const Duration(hours: 1),
                                        ),
                                );
                              }
                              error = null;
                            }),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        children: [
                          column(true),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 18),
                            child: Icon(Icons.chevron_right, color: mutedColor),
                          ),
                          column(false),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 264,
                      child: CalendarDateWheel(
                        child: CupertinoDatePicker(
                          itemExtent: 49,
                          selectionOverlayBuilder: (
                            _, {
                            required columnCount,
                            required selectedIndex,
                          }) => const SizedBox.shrink(),
                          key: ValueKey(
                            '${value.allDay}:$beginning:${value.timezone}',
                          ),
                          mode: value.allDay
                              ? CupertinoDatePickerMode.date
                              : CupertinoDatePickerMode.dateAndTime,
                          initialDateTime: beginning ? value.start : shownEnd,
                          minimumYear: calendarPickerMinYear(
                            beginning ? value.start : shownEnd,
                          ),
                          maximumYear: calendarPickerMaxYear(
                            beginning ? value.start : shownEnd,
                          ),
                          use24hFormat: MediaQuery.alwaysUse24HourFormatOf(
                            context,
                          ),
                          dateOrder: DatePickerDateOrder.ymd,
                          onDateTimeChanged: select,
                        ),
                      ),
                    ),
                    if (!value.allDay) ...[
                      const Divider(height: 28),
                      ListTile(
                        key: const ValueKey('calendar-time-zone'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          calendarTimezones[value.timezone] ?? value.timezone,
                          style: const TextStyle(fontSize: 16),
                        ),
                        subtitle: Text(
                          value.timezone,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final zone = await chooseCalendarTimezone(
                            context,
                            current: value.timezone,
                            valid: widget.valid,
                            identity: widget.identity,
                          );
                          if (zone != null && mounted && widget.valid()) {
                            setState(
                              () => value = value.copyWith(timezone: zone),
                            );
                          }
                        },
                      ),
                    ],
                    if (error != null)
                      Text(
                        error!,
                        style: const TextStyle(color: Colors.red, fontSize: 15),
                      ),
                  ],
                ),
              ),
      );
    },
  );
}

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];
String calendarRepeatLabel(CalendarJson? rule) {
  if (rule == null) return '不重复';
  final every = rule['interval'] ?? 1;
  final unit =
      {
        'daily': '天',
        'weekly': '周',
        'monthly': '个月',
        'yearly': '年',
      }[rule['frequency']] ??
      '';
  var label = '每${every == 1 ? '' : every}$unit';
  if (rule['frequency'] == 'weekly' && rule['weekdays'] is List) {
    label +=
        '（${(rule['weekdays'] as List).map((d) => '周${_weekdays[(d as int) - 1]}').join('、')}）';
  }
  if (rule['frequency'] == 'monthly' && rule['month_day'] != null) {
    label += rule['month_day'] == -1 ? '最后一天' : '${rule['month_day']}日';
  }
  if (rule['ordinal_weekday'] is Map) {
    final o = rule['ordinal_weekday'] as Map;
    label +=
        '${o['ordinal'] == -1 ? '最后' : '第${o['ordinal']}'}个周${_weekdays[(o['weekday'] as int) - 1]}';
  }
  if (rule['count'] != null) label += ' · ${rule['count']}次';
  if (rule['until_date'] != null) label += ' · 至${rule['until_date']}';
  return label;
}

class CalendarRepeatSelection {
  const CalendarRepeatSelection(this.rule);
  final CalendarJson? rule;
}

Future<CalendarRepeatSelection?> showCalendarRepeatPicker(
  BuildContext context, {
  required DateTime start,
  required CalendarJson? current,
  required bool Function() valid,
  required Listenable identity,
  Rect? anchor,
}) async {
  final sourceFocus = _CalendarSubpageFocus();
  try {
    final weekday = start.weekday;
    final ordinal = ((start.day - 1) ~/ 7) + 1;
    final presets = <(String, CalendarJson?)>[
      ('不重复', null),
      ('每天', {'frequency': 'daily', 'interval': 1}),
      (
        '每周${_weekdays[weekday - 1]}',
        {
          'frequency': 'weekly',
          'interval': 1,
          'weekdays': [weekday],
        },
      ),
      (
        '每月第$ordinal个周${_weekdays[weekday - 1]}',
        {
          'frequency': 'monthly',
          'interval': 1,
          'ordinal_weekday': {'ordinal': ordinal, 'weekday': weekday},
        },
      ),
      (
        '每月${start.day}日',
        {'frequency': 'monthly', 'interval': 1, 'month_day': start.day},
      ),
      (
        '每年${start.month}月${start.day}日',
        {
          'frequency': 'yearly',
          'interval': 1,
          'month': start.month,
          'month_day': start.day,
        },
      ),
      (
        '每个工作日（周一至周五）',
        {
          'frequency': 'weekly',
          'interval': 1,
          'weekdays': [1, 2, 3, 4, 5],
        },
      ),
    ];
    final mobile = MediaQuery.sizeOf(context).width < 700;
    Future<Object?> desktopMenu() {
      final overlay =
          Overlay.of(context, rootOverlay: true).context.findRenderObject()
              as RenderBox;
      final topLeft = overlay.localToGlobal(Offset.zero);
      final entry =
          anchor?.shift(-topLeft) ??
          Rect.fromLTWH(
            overlay.size.width / 2 - 120,
            overlay.size.height / 2 - 140,
            240,
            1,
          );
      return showMenu<Object>(
        context: context,
        useRootNavigator: true,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(entry.left, entry.bottom + 4, entry.width, 1),
          Offset.zero & overlay.size,
        ),
        constraints: const BoxConstraints(minWidth: 240, maxWidth: 260),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        items: [
          for (var i = 0; i < presets.length; i++)
            PopupMenuItem<Object>(
              key: ValueKey('calendar-repeat-preset-$i'),
              height: 32,
              value: CalendarRepeatSelection(presets[i].$2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      presets[i].$1,
                      style: TextStyle(
                        fontSize: 14,
                        color:
                            calendarRepeatLabel(current) ==
                                calendarRepeatLabel(presets[i].$2)
                            ? accentColor
                            : inkColor,
                      ),
                    ),
                  ),
                  if (calendarRepeatLabel(current) ==
                      calendarRepeatLabel(presets[i].$2))
                    const Icon(Icons.check, size: 16, color: accentColor),
                ],
              ),
            ),
          const PopupMenuDivider(height: 9),
          const PopupMenuItem<Object>(
            key: ValueKey('calendar-repeat-custom'),
            height: 32,
            value: 'custom',
            child: Text('自定义', style: TextStyle(fontSize: 14)),
          ),
        ],
      );
    }

    final result = !mobile
        ? await desktopMenu()
        : await showDialog<Object>(
            context: context,
            useSafeArea: !mobile,
            builder: (dialog) => AnimatedBuilder(
              animation: identity,
              builder: (_, _) {
                final rows = valid()
                    ? <Widget>[
                        for (var i = 0; i < presets.length; i++)
                          ListTile(
                            key: ValueKey('calendar-repeat-preset-$i'),
                            minTileHeight: mobile ? 48 : null,
                            visualDensity: mobile
                                ? VisualDensity.standard
                                : null,
                            title: Text(
                              presets[i].$1,
                              style: TextStyle(
                                fontSize: 16,
                                color:
                                    calendarRepeatLabel(current) ==
                                        calendarRepeatLabel(presets[i].$2)
                                    ? accentColor
                                    : inkColor,
                              ),
                            ),
                            trailing:
                                calendarRepeatLabel(current) ==
                                    calendarRepeatLabel(presets[i].$2)
                                ? const Icon(
                                    Icons.check,
                                    color: accentColor,
                                    size: 20,
                                  )
                                : null,
                            onTap: () {
                              if (valid()) {
                                Navigator.pop(
                                  dialog,
                                  CalendarRepeatSelection(presets[i].$2),
                                );
                              }
                            },
                          ),
                        const Divider(height: 1),
                        ListTile(
                          key: const ValueKey('calendar-repeat-custom'),
                          title: const Text(
                            '自定义',
                            style: TextStyle(fontSize: 16),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            if (valid()) Navigator.pop(dialog, 'custom');
                          },
                        ),
                      ]
                    : <Widget>[
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('身份或权限已改变，请返回。'),
                        ),
                      ];
                if (mobile) {
                  return Dialog(
                    insetPadding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    surfaceTintColor: Colors.transparent,
                    child: SizedBox.expand(
                      child: SafeArea(
                        child: Column(
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  tooltip: '返回日程',
                                  onPressed: () => Navigator.pop(dialog),
                                  icon: const Icon(
                                    Icons.chevron_left,
                                    size: 28,
                                  ),
                                ),
                                const Expanded(
                                  child: Text(
                                    '选择重复',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 17),
                                  ),
                                ),
                                const SizedBox(width: 48),
                              ],
                            ),
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.only(top: 28),
                                children: rows,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }
                return AlertDialog(
                  backgroundColor: Colors.white,
                  title: Text(valid() ? '重复' : '当前日程已过期'),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  content: SizedBox(
                    width: 370,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: rows,
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('取消'),
                    ),
                  ],
                );
              },
            ),
          );
    if (!context.mounted || !valid()) return null;
    if (result == 'custom') {
      return await showDialog<CalendarRepeatSelection>(
        context: context,
        useSafeArea: MediaQuery.sizeOf(context).width >= 700,
        builder: (_) => _CustomRepeat(
          start: start,
          initial: current,
          valid: valid,
          identity: identity,
        ),
      );
    }
    return result is CalendarRepeatSelection ? result : null;
  } finally {
    sourceFocus.restore();
  }
}

class _CustomRepeat extends StatefulWidget {
  const _CustomRepeat({
    required this.start,
    this.initial,
    required this.valid,
    required this.identity,
  });
  final DateTime start;
  final CalendarJson? initial;
  final bool Function() valid;
  final Listenable identity;
  @override
  State<_CustomRepeat> createState() => _CustomRepeatState();
}

class _CustomRepeatState extends State<_CustomRepeat> {
  final Map<String, FixedExtentScrollController> _wheelControllers = {};
  @override
  void dispose() {
    for (final controller in _wheelControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  late String frequency = widget.initial?['frequency'] as String? ?? 'daily';
  late int interval = widget.initial?['interval'] as int? ?? 1;
  late final int _originalInterval = interval;
  List<int> get _intervalChoices => [
    ...List.generate(99, (i) => i + 1),
    if (_originalInterval > 99) _originalInterval,
  ];
  late Set<int> weekdays =
      (widget.initial?['weekdays'] as List? ?? [widget.start.weekday])
          .cast<int>()
          .toSet();
  late bool ordinalMode = widget.initial?['ordinal_weekday'] is Map;
  late int monthDay = widget.initial?['month_day'] as int? ?? widget.start.day;
  late int ordinal =
      (widget.initial?['ordinal_weekday'] as Map?)?['ordinal'] as int? ??
      ((widget.start.day - 1) ~/ 7) + 1;
  late int weekday =
      (widget.initial?['ordinal_weekday'] as Map?)?['weekday'] as int? ??
      widget.start.weekday;
  late int month = widget.initial?['month'] as int? ?? widget.start.month;
  late String ending = widget.initial?['count'] != null
      ? 'count'
      : widget.initial?['until_date'] != null
      ? 'until'
      : 'never';
  late int count = widget.initial?['count'] as int? ?? 10;
  late DateTime until =
      calendarParseDate(widget.initial?['until_date']) ??
      DateTime(widget.start.year, widget.start.month + 1, widget.start.day);
  String? error;
  CalendarJson rule() => {
    'frequency': frequency,
    'interval': interval,
    if (frequency == 'weekly') 'weekdays': weekdays.toList()..sort(),
    if (frequency == 'monthly' || frequency == 'yearly') ...{
      if (ordinalMode)
        'ordinal_weekday': {'ordinal': ordinal, 'weekday': weekday}
      else
        'month_day': monthDay,
    },
    if (frequency == 'yearly') 'month': month,
    if (ending == 'count') 'count': count,
    if (ending == 'until') 'until_date': calendarDate(until),
  };
  Widget numbers(
    String key,
    int selected,
    List<int> values,
    ValueChanged<int> change,
    String Function(int) label,
  ) => DropdownButton<int>(
    key: ValueKey(key),
    isExpanded: true,
    value: selected,
    items: values
        .map(
          (n) => DropdownMenuItem(
            value: n,
            child: Text(label(n), style: const TextStyle(fontSize: 16)),
          ),
        )
        .toList(),
    onChanged: (n) {
      if (n != null) setState(() => change(n));
    },
  );
  Widget wheel(
    String key,
    int selected,
    List<String> labels,
    ValueChanged<int> change,
  ) => CupertinoPicker(
    key: ValueKey(key),
    scrollController: _wheelControllers.putIfAbsent(
      key,
      () => FixedExtentScrollController(initialItem: selected),
    ),
    itemExtent: 49,
    selectionOverlay: const SizedBox.shrink(),
    onSelectedItemChanged: (i) {
      if (widget.valid()) setState(() => change(i));
    },
    children: labels
        .map(
          (text) =>
              Center(child: Text(text, style: const TextStyle(fontSize: 20))),
        )
        .toList(),
  );
  Widget mobileFrequency() => SizedBox(
    height: 150,
    child: Row(
      children: [
        const Text('每', style: TextStyle(fontSize: 17)),
        Expanded(
          child: wheel(
            'calendar-repeat-interval-wheel',
            _intervalChoices.indexOf(interval),
            _intervalChoices.map((i) => '$i').toList(),
            (i) => interval = _intervalChoices[i],
          ),
        ),
        Expanded(
          child: wheel(
            'calendar-repeat-frequency-wheel',
            ['daily', 'weekly', 'monthly', 'yearly'].indexOf(frequency),
            ['天', '周', '个月', '年'],
            (i) => frequency = ['daily', 'weekly', 'monthly', 'yearly'][i],
          ),
        ),
      ],
    ),
  );
  Widget mobileWeekdays() => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
      mainAxisExtent: 74,
    ),
    itemCount: 9,
    itemBuilder: (_, i) {
      final day = i == 0 ? 7 : i;
      final ids = i == 7
          ? {1, 2, 3, 4, 5}
          : i == 8
          ? {6, 7}
          : {day};
      final selected = ids.every(weekdays.contains);
      return InkWell(
        key: ValueKey('calendar-repeat-week-cell-$i'),
        onTap: () {
          if (widget.valid()) {
            setState(() {
              if (i >= 7) {
                weekdays = ids;
              } else {
                selected ? weekdays.remove(day) : weekdays.add(day);
              }
            });
          }
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: .5),
          ),
          alignment: Alignment.center,
          child: Text(
            i == 7
                ? '工作日'
                : i == 8
                ? '周末'
                : '周${_weekdays[day - 1]}',
            style: TextStyle(
              fontSize: 16,
              color: selected ? accentColor : mutedColor,
            ),
          ),
        ),
      );
    },
  );
  Widget mobileMonth() => Column(
    children: [
      if (frequency == 'yearly')
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: numbers(
            'calendar-repeat-month',
            month,
            List.generate(12, (i) => i + 1),
            (n) => month = n,
            (n) => '$n月',
          ),
        ),
      if (ordinalMode)
        SizedBox(
          height: 150,
          child: Row(
            children: [
              Expanded(
                child: wheel(
                  'calendar-repeat-ordinal-wheel',
                  [1, 2, 3, 4, 5, -1].indexOf(ordinal),
                  ['第1个', '第2个', '第3个', '第4个', '第5个', '最后一个'],
                  (i) => ordinal = [1, 2, 3, 4, 5, -1][i],
                ),
              ),
              Expanded(
                child: wheel(
                  'calendar-repeat-ordinal-weekday-wheel',
                  weekday - 1,
                  _weekdays.map((d) => '周$d').toList(),
                  (i) => weekday = i + 1,
                ),
              ),
            ],
          ),
        )
      else
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisExtent: 46,
          ),
          itemCount: 35,
          itemBuilder: (_, i) => i > 31
              ? const SizedBox()
              : Semantics(
                  label: i == 31 ? '每月最后一天' : '${i + 1}日',
                  button: true,
                  child: InkWell(
                    key: ValueKey('calendar-repeat-month-cell-${i + 1}'),
                    onTap: () {
                      if (widget.valid()) {
                        setState(() => monthDay = i == 31 ? -1 : i + 1);
                      }
                    },
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: borderColor, width: .5),
                      ),
                      child: Text(
                        i == 31 ? '末日' : '${i + 1}',
                        style: TextStyle(
                          fontSize: i == 31 ? 13 : 16,
                          color: monthDay == (i == 31 ? -1 : i + 1)
                              ? accentColor
                              : mutedColor,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      SizedBox(
        height: 48,
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => setState(() => ordinalMode = false),
                child: Text(
                  '日期',
                  style: TextStyle(
                    fontSize: 16,
                    color: !ordinalMode ? accentColor : mutedColor,
                  ),
                ),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () => setState(() => ordinalMode = true),
                child: Text(
                  '星期',
                  style: TextStyle(
                    fontSize: 16,
                    color: ordinalMode ? accentColor : mutedColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget mobileBody() => LayoutBuilder(
    builder: (context, bounds) {
      if (!widget.valid()) return const Center(child: Text('身份或日程权限已改变，请返回。'));
      final monthly = frequency == 'monthly' || frequency == 'yearly';
      final selectorHeight = frequency == 'weekly'
          ? 222.0
          : monthly
          ? (ordinalMode ? 198.0 : 278.0) + (frequency == 'yearly' ? 56 : 0)
          : 0.0;
      final headingHeight =
          44 + MediaQuery.textScalerOf(context).scale(20) * 1.2 + 20 + 150;
      return SingleChildScrollView(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    calendarRepeatLabel(rule()),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 20),
                  mobileFrequency(),
                ],
              ),
            ),
            if (frequency == 'weekly' || monthly) ...[
              SizedBox(
                height:
                    (bounds.maxHeight -
                            headingHeight -
                            selectorHeight -
                            (error == null ? 0 : 48))
                        .clamp(24.0, 9999.0),
              ),
              if (frequency == 'weekly') mobileWeekdays() else mobileMonth(),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      );
    },
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.identity,
    builder: (_, _) {
      final mobile = MediaQuery.sizeOf(context).width < 700;
      final valid = widget.valid();
      void done() {
        if (!widget.valid()) return;
        if (frequency == 'weekly' && weekdays.isEmpty) {
          setState(() => error = '请选择至少一个星期');
          return;
        }
        if (ending == 'until' &&
            calendarDay(until).isBefore(calendarDay(widget.start))) {
          setState(() => error = '截止日期不能早于开始日期');
          return;
        }
        Navigator.pop(context, CalendarRepeatSelection(rule()));
      }

      final form = !valid
          ? const Text('身份或日程权限已改变，请返回。')
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  calendarRepeatLabel(rule()),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 20),
                if (mobile)
                  mobileFrequency()
                else
                  Row(
                    children: [
                      const Text('每', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 20),
                      Expanded(
                        child: numbers(
                          'calendar-repeat-interval',
                          interval,
                          _intervalChoices,
                          (n) => interval = n,
                          (n) => '$n',
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: DropdownButton<String>(
                          key: const ValueKey('calendar-repeat-frequency'),
                          isExpanded: true,
                          value: frequency,
                          items: const [
                            DropdownMenuItem(value: 'daily', child: Text('天')),
                            DropdownMenuItem(value: 'weekly', child: Text('周')),
                            DropdownMenuItem(
                              value: 'monthly',
                              child: Text('个月'),
                            ),
                            DropdownMenuItem(value: 'yearly', child: Text('年')),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => frequency = v);
                          },
                        ),
                      ),
                    ],
                  ),
                if (frequency == 'weekly' && mobile) mobileWeekdays(),
                if (frequency == 'weekly' && !mobile) ...[
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(
                      7,
                      (i) => FilterChip(
                        key: ValueKey('calendar-repeat-weekday-${i + 1}'),
                        label: Text('周${_weekdays[i]}'),
                        selected: weekdays.contains(i + 1),
                        onSelected: (yes) => setState(
                          () => yes
                              ? weekdays.add(i + 1)
                              : weekdays.remove(i + 1),
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => weekdays = {1, 2, 3, 4, 5}),
                    child: const Text('工作日'),
                  ),
                ],
                if ((frequency == 'monthly' || frequency == 'yearly') && mobile)
                  mobileMonth(),
                if ((frequency == 'monthly' || frequency == 'yearly') &&
                    !mobile) ...[
                  if (frequency == 'yearly')
                    numbers(
                      'calendar-repeat-month',
                      month,
                      List.generate(12, (i) => i + 1),
                      (n) => month = n,
                      (n) => '$n月',
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('按星期重复'),
                    value: ordinalMode,
                    onChanged: (v) => setState(() => ordinalMode = v),
                  ),
                  if (ordinalMode)
                    Row(
                      children: [
                        Expanded(
                          child: numbers(
                            'calendar-repeat-ordinal',
                            ordinal,
                            [1, 2, 3, 4, 5, -1],
                            (n) => ordinal = n,
                            (n) => n == -1 ? '最后一个' : '第$n个',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: numbers(
                            'calendar-repeat-ordinal-weekday',
                            weekday,
                            [1, 2, 3, 4, 5, 6, 7],
                            (n) => weekday = n,
                            (n) => '周${_weekdays[n - 1]}',
                          ),
                        ),
                      ],
                    )
                  else
                    numbers(
                      'calendar-repeat-month-day',
                      monthDay,
                      [...List.generate(31, (i) => i + 1), -1],
                      (n) => monthDay = n,
                      (n) => n == -1 ? '最后一天' : '$n日',
                    ),
                ],
                if (!mobile) ...[
                  const Divider(height: 30),
                  const Text(
                    '截止时间',
                    style: TextStyle(fontSize: 16, color: mutedColor),
                  ),
                  for (final entry in {
                    'never': '永不截止',
                    'until': '截止日期',
                    'count': '重复次数',
                  }.entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        ending == entry.key
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: ending == entry.key ? accentColor : mutedColor,
                      ),
                      title: Text(entry.value),
                      onTap: () => setState(() => ending = entry.key),
                    ),
                  if (ending == 'until')
                    OutlinedButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: until.isBefore(calendarDay(widget.start))
                              ? calendarDay(widget.start)
                              : until,
                          firstDate: calendarDay(widget.start),
                          lastDate: DateTime(
                            calendarPickerMaxYear(
                                  until.isBefore(widget.start)
                                      ? widget.start
                                      : until,
                                ) +
                                1,
                          ),
                        );
                        if (date != null && mounted && widget.valid()) {
                          setState(() => until = date);
                        }
                      },
                      child: Text(calendarDateLabel(until)),
                    ),
                  if (ending == 'count')
                    numbers(
                      'calendar-repeat-count',
                      count,
                      [
                        ...List.generate(100, (i) => i + 1),
                        if (count > 100) count,
                      ],
                      (n) => count = n,
                      (n) => '$n次',
                    ),
                ],
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            );
      final content = SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '取消重复设置',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.chevron_left, size: 28),
                  ),
                  const Expanded(
                    child: Text(
                      '自定义重复',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 17),
                    ),
                  ),
                  TextButton(
                    onPressed: valid ? done : null,
                    child: const Text('完成', style: TextStyle(fontSize: 17)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: mobileBody()),
          ],
        ),
      );
      return mobile
          ? Dialog(
              insetPadding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              child: SizedBox(
                width: double.infinity,
                height: double.infinity,
                child: content,
              ),
            )
          : AlertDialog(
              backgroundColor: Colors.white,
              title: const Text('自定义重复'),
              content: SizedBox(
                width: 400,
                child: SingleChildScrollView(child: form),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: valid ? done : null,
                  child: const Text('确定'),
                ),
              ],
            );
    },
  );
}

String calendarRepeatEndLabel(CalendarJson rule) => rule['count'] != null
    ? '重复 ${rule['count']} 次后截止'
    : rule['until_date'] != null
    ? '截止至 ${rule['until_date']}'
    : '永不截止';
Future<CalendarRepeatSelection?> showCalendarRepeatEndPage(
  BuildContext context, {
  required DateTime start,
  required CalendarJson rule,
  required bool Function() valid,
  required Listenable identity,
}) async {
  final sourceFocus = _CalendarSubpageFocus();
  try {
    return await Navigator.of(
      context,
      rootNavigator: true,
    ).push<CalendarRepeatSelection>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _CalendarRepeatEndPage(
          start: start,
          initial: rule,
          valid: valid,
          identity: identity,
        ),
      ),
    );
  } finally {
    sourceFocus.restore();
  }
}

class _CalendarRepeatEndPage extends StatefulWidget {
  const _CalendarRepeatEndPage({
    required this.start,
    required this.initial,
    required this.valid,
    required this.identity,
  });
  final DateTime start;
  final CalendarJson initial;
  final bool Function() valid;
  final Listenable identity;
  @override
  State<_CalendarRepeatEndPage> createState() => _CalendarRepeatEndPageState();
}

class _CalendarRepeatEndPageState extends State<_CalendarRepeatEndPage> {
  late bool never =
      widget.initial['count'] == null && widget.initial['until_date'] == null;
  late bool byCount = widget.initial['count'] != null;
  late int count = widget.initial['count'] as int? ?? 10;
  late DateTime until =
      calendarParseDate(widget.initial['until_date']) ??
      DateTime(widget.start.year, widget.start.month + 1, widget.start.day);
  String? error;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.identity,
    builder: (_, _) {
      final valid = widget.valid();
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          title: const Text('选择截止时间', style: TextStyle(fontSize: 17)),
          leadingWidth: 80,
          leading: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              '取消',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 16, color: inkColor),
            ),
          ),
          actions: [
            TextButton(
              onPressed: !valid
                  ? null
                  : () {
                      if (!widget.valid()) return;
                      if (!never &&
                          !byCount &&
                          calendarDay(until)
                              .isBefore(calendarDay(widget.start))) {
                        setState(() => error = '截止日期不能早于开始日期');
                        return;
                      }
                      final rule = Map<String, dynamic>.from(widget.initial)
                        ..remove('count')
                        ..remove('until_date');
                      if (!never) {
                        if (byCount) {
                          rule['count'] = count;
                        } else {
                          rule['until_date'] = calendarDate(until);
                        }
                      }
                      Navigator.pop(context, CalendarRepeatSelection(rule));
                    },
              child: const Text('完成', style: TextStyle(fontSize: 17)),
            ),
          ],
        ),
        body: !valid
            ? const Center(child: Text('身份或日程权限已改变，请返回。'))
            : SafeArea(
                top: false,
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    SwitchListTile(
                      key: const ValueKey('calendar-repeat-never-end'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('永不截止', style: TextStyle(fontSize: 17)),
                      value: never,
                      onChanged: (value) => setState(() {
                        never = value;
                        error = null;
                      }),
                    ),
                    const Divider(height: 1),
                    if (!never) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Text(
                          '选择截止时间',
                          style: TextStyle(fontSize: 13, color: mutedColor),
                        ),
                      ),
                      if (!byCount)
                        SizedBox(
                          height: 264,
                          child: CalendarDateWheel(
                            child: CupertinoDatePicker(
                              itemExtent: 49,
                              selectionOverlayBuilder: (
                                _, {
                                required columnCount,
                                required selectedIndex,
                              }) => const SizedBox.shrink(),
                              key: const ValueKey('calendar-repeat-end-wheel'),
                              mode: CupertinoDatePickerMode.date,
                              dateOrder: DatePickerDateOrder.ymd,
                              initialDateTime: until,
                              minimumYear: calendarPickerMinYear(until),
                              maximumYear: calendarPickerMaxYear(until),
                              onDateTimeChanged: (date) {
                                if (widget.valid()) {
                                  setState(() => until = calendarDay(date));
                                }
                              },
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 30),
                          child: DropdownButton<int>(
                            key: const ValueKey('calendar-repeat-end-count'),
                            isExpanded: true,
                            value: count,
                            items:
                                [
                                      ...List.generate(100, (i) => i + 1),
                                      if (count > 100) count,
                                    ]
                                    .map(
                                      (n) => DropdownMenuItem(
                                        value: n,
                                        child: Text('重复 $n 次'),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (v) {
                              if (v != null && widget.valid()) {
                                setState(() => count = v);
                              }
                            },
                          ),
                        ),
                      TextButton(
                        onPressed: () => setState(() => byCount = !byCount),
                        child: Text(byCount ? '按日期截止' : '按重复次数截止'),
                      ),
                    ],
                    if (error != null)
                      Text(
                        error!,
                        style: const TextStyle(color: Colors.red, fontSize: 15),
                      ),
                  ],
                ),
              ),
      );
    },
  );
}
