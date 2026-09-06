import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeCalendar extends StatefulWidget {
  const OfficeCalendar({
    super.key,
    required this.state,
    required this.onMeeting,
  });
  final OfficeState state;
  final Future<void> Function(String id) onMeeting;
  @override
  State<OfficeCalendar> createState() => OfficeCalendarState();
}

class OfficeCalendarState extends State<OfficeCalendar> {
  Future<void> createEvent() => _edit();
  Future<void> openEvent(Json event) => _detail(event);
  DateTime _selected = DateTime.now();
  OfficeState get s => widget.state;
  DateTime _day(DateTime date) => DateTime(date.year, date.month, date.day);
  DateTime get _monday =>
      _day(_selected).subtract(Duration(days: _selected.weekday - 1));
  DateTime? _time(dynamic value) => DateTime.tryParse(str(value))?.toLocal();
  List<Json> _onDay(DateTime day) =>
      s.calendarEvents.where((e) {
          final start = _time(e['starts_at']), end = _time(e['ends_at']);
          return start != null &&
              end != null &&
              start.isBefore(_day(day).add(const Duration(days: 1))) &&
              end.isAfter(_day(day));
        }).toList()
        ..sort((a, b) => str(a['starts_at']).compareTo(str(b['starts_at'])));
  String _fullTime(DateTime date) =>
      '${date.year}/${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  Future<DateTime?> _pickDateTime(BuildContext context, DateTime value) async {
    final date = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
    );
    if (date == null || !context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    return time == null
        ? null
        : DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _edit([Json? event, DateTime? initial]) async {
    final roomId =
        event?['room_id'] as String? ??
        s.selectedRoomId ??
        await chooseOfficeRoom(context, s);
    if (roomId == null || !mounted) return;
    final title = TextEditingController(text: str(event?['title'])),
        note = TextEditingController(text: str(event?['description'])),
        location = TextEditingController(text: str(event?['location']));
    var start =
        _time(event?['starts_at']) ??
        initial ??
        DateTime(_selected.year, _selected.month, _selected.day, 10);
    var end = _time(event?['ends_at']) ?? start.add(const Duration(hours: 1));
    final attendees = (event?['attendee_ids'] as List? ?? [s.me?['id']])
        .map((p) => p.toString())
        .toSet();
    final people = officeRoomPeople(s, roomId);
    String? error;
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text(
            event == null ? '新建日程' : '编辑日程',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: '日程主题',
                      hintText: '写下这段时间共同推进的事情',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '会话：${officeRoomName(s, roomId)}',
                    style: const TextStyle(fontSize: 11, color: mutedColor),
                  ),
                  const SizedBox(height: 15),
                  _dateField('开始时间', _fullTime(start), () async {
                    final value = await _pickDateTime(context, start);
                    if (value != null) {
                      change(() {
                        start = value;
                        if (!end.isAfter(start)) {
                          end = start.add(const Duration(hours: 1));
                        }
                      });
                    }
                  }),
                  const SizedBox(height: 10),
                  _dateField('结束时间', _fullTime(end), () async {
                    final value = await _pickDateTime(context, end);
                    if (value != null) change(() => end = value);
                  }),
                  const SizedBox(height: 18),
                  TextField(
                    controller: location,
                    maxLength: 300,
                    decoration: const InputDecoration(
                      labelText: '地点',
                      hintText: '会议室、线上讨论或其他地点',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '日程说明',
                      hintText: '背景、议题与准备事项',
                    ),
                  ),
                  const SizedBox(height: 19),
                  const Text(
                    '参与成员',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: people
                        .map(
                          (p) => FilterChip(
                            label: Text(
                              '${str(p['name'])}${p['kind'] == 'agent' ? ' · Agent' : ''}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: attendees.contains(personId(p)),
                            onSelected: (selected) => change(() {
                              selected
                                  ? attendees.add(personId(p))
                                  : attendees.remove(personId(p));
                            }),
                            visualDensity: VisualDensity.compact,
                            side: const BorderSide(color: borderColor),
                          ),
                        )
                        .toList(),
                  ),
                  if (event != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 14),
                      child: Text(
                        '改期后，成员会重新确认参与意向。',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        error!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (title.text.trim().isEmpty || !end.isAfter(start)) {
                        change(
                          () => error = title.text.trim().isEmpty
                              ? '请填写日程主题'
                              : '结束时间必须晚于开始时间',
                        );
                        return;
                      }
                      change(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        if (event == null) {
                          await s.createCalendarEvent(
                            roomId: roomId,
                            title: title.text.trim(),
                            startsAt: start.toUtc().toIso8601String(),
                            endsAt: end.toUtc().toIso8601String(),
                            description: note.text,
                            location: location.text,
                            attendeeIds: attendees.toList(),
                          );
                        } else {
                          await s.updateCalendarEvent(event, {
                            'title': title.text.trim(),
                            'starts_at': start.toUtc().toIso8601String(),
                            'ends_at': end.toUtc().toIso8601String(),
                            'description': note.text,
                            'location': location.text,
                            'attendee_ids': attendees.toList(),
                          });
                        }
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (e) {
                        if (dialogContext.mounted) {
                          change(() {
                            busy = false;
                            error = friendlyError(e);
                          });
                        }
                      }
                    },
              child: Text(
                busy
                    ? '正在保存…'
                    : event == null
                    ? '创建日程'
                    : '保存修改',
              ),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    note.dispose();
    location.dispose();
  }

  Widget _dateField(String label, String value, VoidCallback action) => InkWell(
    onTap: action,
    borderRadius: BorderRadius.circular(7),
    child: Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xfff5f6f8),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: mutedColor)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          const Icon(Icons.schedule, size: 17, color: mutedColor),
        ],
      ),
    ),
  );
  Future<void> _detail(Json initial) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: s,
        builder: (context, _) {
          final event =
              s.calendarEvents
                  .where((e) => e['id'] == initial['id'])
                  .firstOrNull ??
              initial;
          final start = _time(event['starts_at']),
              end = _time(event['ends_at']);
          final attendees = (event['attendee_ids'] as List? ?? [])
              .map((p) => p.toString())
              .toList();
          final responses = event['responses'] is Map
              ? event['responses'] as Map
              : {};
          final myResponse = responses[s.me?['id']];
          return AlertDialog(
            title: Text(
              str(event['title']),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (start != null && end != null)
                      Text(
                        '${_fullTime(start)} — ${_fullTime(end)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: accentColor,
                        ),
                      ),
                    if (str(event['location']).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.location_on_outlined,
                              size: 17,
                              color: mutedColor,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                str(event['location']),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (str(event['description']).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Text(
                          str(event['description']),
                          style: const TextStyle(fontSize: 12, height: 1.8),
                        ),
                      ),
                    const Divider(height: 28),
                    const Text(
                      '参与成员',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...attendees.map((id) {
                      final p =
                          s.principals
                              .where((p) => personId(p) == id)
                              .firstOrNull ??
                          {};
                      final response = responses[id];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            PersonAvatar(
                              name: str(p['name'], '工作成员'),
                              agent: p['kind'] == 'agent',
                              size: 28,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                str(p['name'], '工作成员'),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Text(
                              const {
                                    'accepted': '已接受',
                                    'declined': '已拒绝',
                                    'tentative': '待定',
                                  }[response] ??
                                  '未回应',
                              style: TextStyle(
                                fontSize: 10,
                                color: response == 'accepted'
                                    ? const Color(0xff42a57a)
                                    : mutedColor,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    if (attendees.contains(str(s.me?['id']))) ...[
                      const Divider(height: 28),
                      const Text(
                        '你的参与意向',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: ['accepted', 'tentative', 'declined']
                            .map(
                              (response) => ChoiceChip(
                                label: Text(
                                  const {
                                    'accepted': '接受',
                                    'tentative': '待定',
                                    'declined': '拒绝',
                                  }[response]!,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                selected: myResponse == response,
                                onSelected: (_) async {
                                  try {
                                    await s.respondCalendarEvent(
                                      str(event['id']),
                                      response,
                                    );
                                  } catch (e) {
                                    if (context.mounted) {
                                      notifyOffice(context, friendlyError(e));
                                    }
                                  }
                                },
                                side: const BorderSide(color: borderColor),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
              if (event['created_by'] == s.me?['id'])
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    _edit(event);
                  },
                  child: const Text('编辑日程'),
                ),
              if (event['meeting_id'] != null)
                FilledButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    widget.onMeeting(str(event['meeting_id']));
                  },
                  child: const Text('加入会议'),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth > 650;
      return Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              desktop ? 24 : 19,
              22,
              desktop ? 24 : 19,
              15,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    desktop ? '${_selected.year} 年 ${_selected.month} 月' : '日历',
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(
                    () =>
                        _selected = _selected.subtract(const Duration(days: 7)),
                  ),
                  tooltip: '上一周',
                  icon: const Icon(Icons.chevron_left, size: 20),
                ),
                TextButton(
                  onPressed: () => setState(() => _selected = DateTime.now()),
                  child: const Text('今天'),
                ),
                IconButton(
                  onPressed: () => setState(
                    () => _selected = _selected.add(const Duration(days: 7)),
                  ),
                  tooltip: '下一周',
                  icon: const Icon(Icons.chevron_right, size: 20),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(
                    desktop ? '新建日程' : '新建',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: desktop
                ? Row(
                    children: [
                      if (constraints.maxWidth > 900) _miniMonth(),
                      Expanded(child: _weekGrid()),
                    ],
                  )
                : _agenda(),
          ),
        ],
      );
    },
  );
  Widget _miniMonth() {
    final first = DateTime(_selected.year, _selected.month, 1),
        count = DateTime(_selected.year, _selected.month + 1, 0).day;
    final gap = first.weekday - 1;
    return Container(
      width: 205,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: borderColor)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_selected.year} 年 ${_selected.month} 月',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          Row(
            children: ['一', '二', '三', '四', '五', '六', '日']
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: const TextStyle(fontSize: 9, color: mutedColor),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: .95,
            ),
            itemCount: ((gap + count) / 7).ceil() * 7,
            itemBuilder: (context, index) {
              final n = index - gap + 1;
              if (n < 1 || n > count) return const SizedBox();
              final date = DateTime(_selected.year, _selected.month, n);
              final selected = _day(date) == _day(_selected);
              return InkWell(
                onTap: () => setState(() => _selected = date),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? accentColor : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$n',
                    style: TextStyle(
                      fontSize: 10,
                      color: selected ? Colors.white : inkColor,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 30),
          const Text('我的日历', style: TextStyle(fontSize: 11, color: mutedColor)),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text('共同工作日程', style: TextStyle(fontSize: 11)),
            ],
          ),
          const SizedBox(height: 18),
          const Text(
            '当前时区：本机时间\n人和 Agent 都可以被邀请，并独立回应日程。',
            style: TextStyle(fontSize: 10, color: mutedColor, height: 1.8),
          ),
        ],
      ),
    );
  }

  Widget _weekGrid() => LayoutBuilder(
    builder: (context, constraints) {
      const hourHeight = 55.0, firstHour = 6, hours = 18;
      final columnWidth = (constraints.maxWidth - 49) / 7;
      final days = List.generate(7, (i) => _monday.add(Duration(days: i)));
      return Column(
        children: [
          SizedBox(
            height: 66,
            child: Row(
              children: [
                const SizedBox(width: 49),
                ...days.map((day) {
                  final today = _day(day) == _day(DateTime.now());
                  return SizedBox(
                    width: columnWidth,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '周${['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1]}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          width: 25,
                          height: 25,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: today ? accentColor : Colors.transparent,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${day.day}',
                            style: TextStyle(
                              fontSize: 14,
                              color: today ? Colors.white : inkColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              child: SizedBox(
                height: hours * hourHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 49,
                      child: Column(
                        children: List.generate(
                          hours,
                          (i) => SizedBox(
                            height: hourHeight,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Text(
                                '${(i + firstHour).toString().padLeft(2, '0')}:00',
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: mutedColor,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ...days.map((day) {
                      final dayEvents = _onDay(day),
                          laneEnds = <DateTime>[],
                          lanes = <int>[];
                      for (final event in dayEvents) {
                        final start = _time(event['starts_at'])!,
                            end = _time(event['ends_at'])!;
                        var lane = laneEnds.indexWhere(
                          (value) => !value.isAfter(start),
                        );
                        if (lane < 0) {
                          lane = laneEnds.length;
                          laneEnds.add(end);
                        } else {
                          laneEnds[lane] = end;
                        }
                        lanes.add(lane);
                      }
                      final laneCount = math.max(1, laneEnds.length);
                      return SizedBox(
                        width: columnWidth,
                        child: Stack(
                          children: [
                            Column(
                              children: List.generate(
                                hours,
                                (i) => InkWell(
                                  onTap: () => _edit(
                                    null,
                                    DateTime(
                                      day.year,
                                      day.month,
                                      day.day,
                                      firstHour + i,
                                    ),
                                  ),
                                  child: Container(
                                    height: hourHeight,
                                    decoration: const BoxDecoration(
                                      border: Border(
                                        top: BorderSide(color: borderColor),
                                        left: BorderSide(color: borderColor),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            ...List.generate(dayEvents.length, (i) {
                              final event = dayEvents[i];
                              final start = _time(event['starts_at'])!,
                                  end = _time(event['ends_at'])!;
                              final origin = DateTime(
                                    day.year,
                                    day.month,
                                    day.day,
                                    firstHour,
                                  ),
                                  finish = origin.add(
                                    const Duration(hours: hours),
                                  );
                              final startMinutes = math.max(
                                    0,
                                    start.difference(origin).inMinutes,
                                  ),
                                  endMinutes = math.min(
                                    hours * 60,
                                    end.difference(origin).inMinutes,
                                  );
                              if (start.isAfter(finish) || endMinutes <= 0) {
                                return const SizedBox();
                              }
                              final top = startMinutes / 60 * hourHeight,
                                  height = math.max(
                                    23.0,
                                    (endMinutes - startMinutes) /
                                        60 *
                                        hourHeight,
                                  );
                              return Positioned(
                                top: top,
                                left:
                                    3 +
                                    lanes[i] * (columnWidth - 5) / laneCount,
                                width: (columnWidth - 5) / laneCount - 2,
                                height: math.min(
                                  height,
                                  hours * hourHeight - top,
                                ),
                                child: InkWell(
                                  onTap: () => _detail(event),
                                  child: Container(
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xffe8efff),
                                      borderRadius: BorderRadius.circular(4),
                                      border: const Border(
                                        left: BorderSide(
                                          color: accentColor,
                                          width: 3,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            str(event['title']),
                                            overflow: TextOverflow.fade,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Color(0xff3766bc),
                                              height: 1.4,
                                            ),
                                          ),
                                        ),
                                        if (height > 45)
                                          Text(
                                            clockText(event['starts_at']),
                                            maxLines: 1,
                                            style: const TextStyle(
                                              fontSize: 8,
                                              color: Color(0xff7c97c9),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
  Widget _agenda() {
    final days = List.generate(7, (i) => _monday.add(Duration(days: i))),
        events = _onDay(_selected);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 18),
          child: Row(
            children: days.map((day) {
              final selected = _day(day) == _day(_selected);
              return Expanded(
                child: InkWell(
                  onTap: () => setState(() => _selected = day),
                  child: Column(
                    children: [
                      Text(
                        ['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1],
                        style: const TextStyle(fontSize: 10, color: mutedColor),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: 31,
                        height: 31,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected ? accentColor : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${day.day}',
                          style: TextStyle(
                            fontSize: 15,
                            color: selected ? Colors.white : inkColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(
                          color: _onDay(day).isNotEmpty
                              ? const Color(0xff91abe0)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: events.isEmpty
              ? EmptyOffice(
                  title: '${_selected.month} 月 ${_selected.day} 日，没有待办日程',
                  subtitle: '为专注工作留出时间，或邀请伙伴一起讨论。',
                  icon: Icons.calendar_today_outlined,
                  action: TextButton(
                    onPressed: () => _edit(),
                    child: const Text('新建日程'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(21),
                  itemCount: events.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 17),
                  itemBuilder: (context, index) {
                    final event = events[index];
                    return InkWell(
                      onTap: () => _detail(event),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 52,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  clockText(event['starts_at']),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  clockText(event['ends_at']),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: mutedColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xfff0f4fc),
                                borderRadius: BorderRadius.circular(7),
                                border: const Border(
                                  left: BorderSide(
                                    color: accentColor,
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    str(event['title']),
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (str(event['location']).isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        str(event['location']),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: mutedColor,
                                        ),
                                      ),
                                    ),
                                  if (event['meeting_id'] != null)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Text(
                                        '视频会议',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: accentColor,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
