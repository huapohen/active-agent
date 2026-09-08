import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

enum _CalendarView { day, threeDay, week, month }

class _CalendarIdentity {
  _CalendarIdentity(this.state)
    : generation = state.identityGeneration,
      endpoint = state.endpoint,
      principal = personId(state.me ?? {});
  final OfficeState state;
  final int generation;
  final String endpoint, principal;
  bool current(OfficeState value) =>
      identical(value, state) &&
      value.identityGeneration == generation &&
      value.endpoint == endpoint &&
      personId(value.me ?? {}) == principal;
}

class OfficeCalendar extends StatefulWidget {
  const OfficeCalendar({
    super.key,
    required this.state,
    required this.onMeeting,
    this.mobileHeaderLeading,
  });
  final OfficeState state;
  final Widget? mobileHeaderLeading;
  final Future<void> Function(String id) onMeeting;
  @override
  State<OfficeCalendar> createState() => OfficeCalendarState();
}

class OfficeCalendarState extends State<OfficeCalendar> {
  Future<void> createEvent() => _edit();
  Future<void> openEvent(Json event) => _detail(event);
  DateTime _selected = DateTime.now();
  _CalendarView _view = _CalendarView.week;
  _CalendarView? _chosenView;
  bool _monthExpanded = false;
  final Set<String> _hiddenRooms = {};
  bool _onlyMine = false;
  String _calendarQuery = '';
  double _hourHeight = 48;
  late final ScrollController _timelineScroll = ScrollController(
    initialScrollOffset: math.max(0, DateTime.now().hour - 5) * _hourHeight,
  );
  OfficeState get s => widget.state;
  DateTime _day(DateTime date) => DateTime(date.year, date.month, date.day);
  DateTime get _sunday => DateTime(
    _selected.year,
    _selected.month,
    _selected.day - _selected.weekday % 7,
  );
  DateTime? _time(dynamic value) => DateTime.tryParse(str(value))?.toLocal();
  List<Json> _onDay(DateTime day, {bool filtered = true}) =>
      s.calendarEvents.where((e) {
        final start = _time(e['starts_at']), end = _time(e['ends_at']);
        if (start == null || end == null || !end.isAfter(start)) return false;
        if (filtered && _hiddenRooms.contains(str(e['room_id']))) return false;
        if (filtered &&
            _onlyMine &&
            e['created_by'] != s.me?['id'] &&
            !(e['attendee_ids'] as List? ?? []).contains(s.me?['id'])) {
          return false;
        }
        return start.isBefore(DateTime(day.year, day.month, day.day + 1)) &&
            end.isAfter(_day(day));
      }).toList()..sort(
        (a, b) => str(a['starts_at']).compareTo(str(b['starts_at'])),
      );
  String _fullTime(DateTime date) =>
      '${date.year}年${date.month}月${date.day}日 ${officeHourMinute(date, context: context)}';
  String _dateTitle() {
    if (_view == _CalendarView.month) {
      return '${_selected.year}年${_selected.month}月';
    }
    if (_view == _CalendarView.day) {
      return '${_selected.year}年${_selected.month}月${_selected.day}日';
    }
    if (_view == _CalendarView.threeDay) {
      final end = DateTime(_selected.year, _selected.month, _selected.day + 2);
      return '${_selected.month}月${_selected.day}日 – ${end.month}月${end.day}日';
    }
    final end = DateTime(_sunday.year, _sunday.month, _sunday.day + 6);
    return '${_sunday.year}年${_sunday.month}月${_sunday.day}日 – '
        '${end.month == _sunday.month ? '' : '${end.month}月'}${end.day}日';
  }

  void _step(int delta) => setState(() {
    _selected = _view == _CalendarView.month
        ? DateTime(_selected.year, _selected.month + delta, 1)
        : DateTime(
            _selected.year,
            _selected.month,
            _selected.day +
                delta *
                    (_view == _CalendarView.week
                        ? 7
                        : _view == _CalendarView.threeDay
                        ? 3
                        : 1),
          );
  });
  void _today() {
    final now = DateTime.now();
    setState(() {
      _selected = now;
      _monthExpanded = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_timelineScroll.hasClients) return;
      final target = math.max(0, now.hour - 3) * _hourHeight;
      _timelineScroll.jumpTo(
        target.clamp(0.0, _timelineScroll.position.maxScrollExtent),
      );
    });
  }

  bool _roomCurrent(String roomId) =>
      officeBusinessRooms(s).any((room) => str(room['id']) == roomId);
  bool _canEdit(Json event) {
    final id = personId(s.me ?? {});
    if (id.isEmpty) return false;
    if (event['created_by'] == id) return true;
    if (s.detail?['room']?['id'] == event['room_id']) {
      return maps(s.detail?['members'])
          .any((p) => personId(p) == id && p['role'] == 'owner');
    }
    // roomView publishes created_by, not membership roles. The current room
    // protocol makes its creator the owner and has no owner-transfer operation.
    return s.rooms.any(
      (r) => r['id'] == event['room_id'] && r['created_by'] == id,
    );
  }

  String _zoneLabel(DateTime time) {
    final offset = time.timeZoneOffset;
    final minutes = offset.inMinutes.abs();
    final suffix = minutes % 60 == 0
        ? ''
        : ':${(minutes % 60).toString().padLeft(2, '0')}';
    return 'GMT${offset.isNegative ? '-' : '+'}${minutes ~/ 60}$suffix';
  }

  @override
  void dispose() {
    _timelineScroll.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDateTime(
    BuildContext context,
    DateTime value,
    _CalendarIdentity identity,
  ) async {
    if (!identity.current(s) || !context.mounted) return null;
    final date = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
    );
    if (date == null || !context.mounted || !identity.current(s)) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (time == null || !context.mounted || !identity.current(s)) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<Set<String>?> _chooseAttendees(
    _CalendarIdentity identity,
    String roomId,
    Set<String> selected,
    bool Function() sourceCurrent,
  ) async {
    var query = '';
    String? error;
    final values = {...selected};
    bool current() => mounted && identity.current(s) && sourceCurrent();
    return showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: s,
        builder: (_, _) => StatefulBuilder(
          builder: (context, change) {
            if (!current()) {
              return AlertDialog(
                title: const Text('参与者选择已过期'),
                content: const Text('当前身份或日程权限已改变，请关闭后重新打开。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('关闭'),
                  ),
                ],
              );
            }
            final people = officeRoomPeople(s, roomId)
                .where(
                  (p) =>
                      '${str(p['name'])} ${p['kind'] == 'agent' ? 'Agent' : ''}'
                          .toLowerCase()
                          .contains(query.toLowerCase()),
                )
                .toList();
            final media = MediaQuery.of(context);
            return AlertDialog(
              scrollable: media.size.height - media.viewInsets.bottom < 500,
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              title: const Text('选择参与者'),
              content: SizedBox(
                width: 480,
                height: 390,
                child: Column(
                  children: [
                    TextField(
                      key: const ValueKey('calendar-attendee-search'),
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '搜索人或 Agent',
                        hintStyle: TextStyle(fontSize: 16),
                        prefixIcon: Icon(Icons.search),
                      ),
                      style: const TextStyle(fontSize: 16),
                      onChanged: (value) => change(() => query = value),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: people.length,
                        itemBuilder: (_, i) {
                          final person = people[i], id = personId(person);
                          return CheckboxListTile(
                            key: ValueKey('calendar-attendee-$id'),
                            value: values.contains(id),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.trailing,
                            secondary: PersonAvatar(
                              name: str(person['name']),
                              agent: person['kind'] == 'agent',
                              size: 36,
                            ),
                            title: Text(
                              '${str(person['name'])}${person['kind'] == 'agent' ? ' · Agent' : ''}',
                              style: const TextStyle(fontSize: 16),
                            ),
                            onChanged: (checked) {
                              if (!current()) return;
                              change(() {
                                checked == true
                                    ? values.add(id)
                                    : values.remove(id);
                                error = null;
                              });
                            },
                          );
                        },
                      ),
                    ),
                    if (error != null)
                      Text(
                        error!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.redAccent,
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const ValueKey('calendar-attendee-confirm'),
                  onPressed: () {
                    if (!current()) return;
                    final allowed = officeRoomPeople(
                      s,
                      roomId,
                    ).map(personId).toSet();
                    if (values.any((id) => !allowed.contains(id))) {
                      change(() {
                        values.retainAll(allowed);
                        error = '部分成员已离开会话，请确认剩余参与者。';
                      });
                      return;
                    }
                    Navigator.pop(dialogContext, {...values});
                  },
                  child: Text('确定（${values.length}）'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _edit([Json? event, DateTime? initial]) async {
    final identity = _CalendarIdentity(s);
    final selectedRoom = s.selectedRoomId;
    final roomId =
        event?['room_id'] as String? ??
        selectedRoom ??
        await chooseOfficeRoom(context, s);
    if (roomId == null ||
        !mounted ||
        !identity.current(s) ||
        !_roomCurrent(roomId) ||
        (event != null && !_canEdit(event))) {
      return;
    }
    final title = TextEditingController(text: str(event?['title']));
    final note = TextEditingController(text: str(event?['description']));
    final location = TextEditingController(text: str(event?['location']));
    var start =
        _time(event?['starts_at']) ??
        initial ??
        DateTime(
          _selected.year,
          _selected.month,
          _selected.day,
          DateTime.now().hour + 1,
        );
    var end = _time(event?['ends_at']) ?? start.add(const Duration(hours: 1));
    final previewScroll = ScrollController(
      initialScrollOffset: math.max(0, start.hour - 2) * 48.0,
    );
    final attendees = (event?['attendee_ids'] as List? ?? [identity.principal])
        .map((p) => p.toString())
        .where((p) => p.isNotEmpty)
        .toSet();
    String? error;
    var busy = false;
    bool current() =>
        mounted &&
        identity.current(s) &&
        _roomCurrent(roomId) &&
        (event == null ||
            s.calendarEvents.any((e) => e['id'] == event['id'] && _canEdit(e)));
    late final DialogRoute<void> route;
    route = DialogRoute<void>(
      context: context,
      useSafeArea: MediaQuery.sizeOf(context).width >= 700,
      builder: (dialogContext) => AnimatedBuilder(
        animation: s,
        builder: (_, _) => StatefulBuilder(
          builder: (context, change) {
            final mobile = MediaQuery.sizeOf(context).width < 700;
            if (!current()) {
              return AlertDialog(
                title: const Text('日程草稿已过期'),
                content: const Text('当前身份或工作会话已改变，请关闭后重新打开。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('关闭'),
                  ),
                ],
              );
            }
            Future<void> chooseDate(bool beginning) async {
              if (busy || !current()) return;
              final value = await _pickDateTime(
                context,
                beginning ? start : end,
                identity,
              );
              if (value == null || !context.mounted || !current()) return;
              change(() {
                if (beginning) {
                  start = value;
                  if (!end.isAfter(start)) {
                    end = start.add(const Duration(hours: 1));
                  }
                } else {
                  end = value;
                }
              });
              if (beginning) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted ||
                      !current() ||
                      !previewScroll.hasClients) {
                    return;
                  }
                  previewScroll.jumpTo(
                    (math.max(0, start.hour - 2) * 48.0).clamp(
                      0.0,
                      previewScroll.position.maxScrollExtent,
                    ),
                  );
                });
              }
            }

            Future<void> save() async {
              if (busy || !current()) return;
              final peopleIds = officeRoomPeople(
                s,
                roomId,
              ).map(personId).toSet();
              if (title.text.trim().isEmpty ||
                  !end.isAfter(start) ||
                  attendees.any((id) => !peopleIds.contains(id))) {
                change(
                  () => error = title.text.trim().isEmpty
                      ? '请填写日程主题'
                      : !end.isAfter(start)
                      ? '结束时间必须晚于开始时间'
                      : '参与成员已发生变化，请重新选择',
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
                if (dialogContext.mounted && current() && route.isCurrent) {
                  Navigator.pop(dialogContext);
                }
              } catch (e) {
                if (context.mounted && current()) {
                  change(() {
                    busy = false;
                    error = friendlyError(e);
                  });
                }
              }
            }

            final form = ListView(
              padding: EdgeInsets.all(mobile ? 20 : 28),
              children: [
                TextField(
                  key: const ValueKey('calendar-event-title'),
                  controller: title,
                  enabled: !busy,
                  autofocus: true,
                  maxLength: 200,
                  onChanged: (_) => change(() {}),
                  style: TextStyle(fontSize: mobile ? 22 : 23),
                  decoration: const InputDecoration(
                    hintText: '添加主题',
                    hintStyle: TextStyle(
                      fontSize: 18,
                      color: mutedColor,
                      fontWeight: FontWeight.w400,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    counterText: '',
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(height: 25),
                InkWell(
                  key: const ValueKey('calendar-attendee-entry'),
                  onTap: busy
                      ? null
                      : () async {
                          if (!current()) return;
                          final selected = await _chooseAttendees(
                            identity,
                            roomId,
                            attendees,
                            current,
                          );
                          if (selected == null ||
                              !context.mounted ||
                              !current()) {
                            return;
                          }
                          change(() {
                            attendees.clear();
                            attendees.addAll(selected);
                          });
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.people_outline,
                          size: 20,
                          color: mutedColor,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                attendees.isEmpty
                                    ? '添加参与者'
                                    : '参与者 · ${attendees.length}',
                                style: TextStyle(
                                  fontSize: mobile ? 16 : 14,
                                  height: 1.2,
                                  color: mutedColor,
                                ),
                              ),
                              if (attendees.isNotEmpty) ...[
                                const SizedBox(height: 5),
                                Text(
                                  attendees
                                      .map((id) {
                                        final p = officeRoomPeople(s, roomId)
                                            .where((p) => personId(p) == id)
                                            .firstOrNull;
                                        return '${str(p?['name'], '工作成员')}${p?['kind'] == 'agent' ? ' · Agent' : ''}';
                                      })
                                      .join('、'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: mobile ? 15 : 13,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: mutedColor,
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 35),
                if (mobile)
                  Row(
                    children: [
                      const Icon(Icons.schedule, size: 20, color: mutedColor),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _mobileTimeField(
                          '开始时间',
                          start,
                          busy ? null : () => chooseDate(true),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Icon(
                          Icons.chevron_right,
                          color: mutedColor,
                          size: 22,
                        ),
                      ),
                      Expanded(
                        child: _mobileTimeField(
                          '结束时间',
                          end,
                          busy ? null : () => chooseDate(false),
                        ),
                      ),
                    ],
                  )
                else ...[
                  _dateField(
                    '开始',
                    _fullTime(start),
                    () => chooseDate(true),
                    mobile: false,
                    enabled: !busy,
                  ),
                  const SizedBox(height: 8),
                  _dateField(
                    '结束',
                    _fullTime(end),
                    () => chooseDate(false),
                    mobile: false,
                    enabled: !busy,
                  ),
                ],
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(
                    '本机时区 · ${_zoneLabel(start)}',
                    style: const TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ),
                const Divider(height: 35),
                TextField(
                  controller: location,
                  enabled: !busy,
                  maxLength: 300,
                  style: TextStyle(fontSize: mobile ? 17 : 14),
                  decoration: const InputDecoration(
                    hintText: '添加地点',
                    hintStyle: TextStyle(fontSize: 17, color: mutedColor),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    prefixIcon: Icon(Icons.location_on_outlined, size: 20),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: note,
                  enabled: !busy,
                  minLines: 3,
                  maxLines: 6,
                  style: TextStyle(fontSize: mobile ? 17 : 14),
                  decoration: const InputDecoration(
                    hintText: '添加描述',
                    hintStyle: TextStyle(fontSize: 17, color: mutedColor),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    prefixIcon: Icon(Icons.notes_outlined, size: 20),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    const Icon(
                      Icons.chat_bubble_outline,
                      size: 18,
                      color: mutedColor,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        officeRoomName(s, roomId),
                        style: TextStyle(
                          fontSize: mobile ? 14 : 13,
                          color: mutedColor,
                        ),
                      ),
                    ),
                  ],
                ),
                if (event != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text(
                      '改期后，成员会重新确认参与意向。',
                      style: TextStyle(fontSize: 12, color: mutedColor),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 14,
                      ),
                    ),
                  ),
              ],
            );
            final content = Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(mobile ? 8 : 20, 8, 12, 8),
                  child: Row(
                    children: [
                      if (mobile)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => Navigator.pop(dialogContext),
                          child: const Text(
                            '取消',
                            style: TextStyle(fontSize: 16, color: inkColor),
                          ),
                        )
                      else
                        IconButton(
                          onPressed: busy
                              ? null
                              : () => Navigator.pop(dialogContext),
                          tooltip: '取消日程',
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      Expanded(
                        child: mobile
                            ? const SizedBox()
                            : Text(
                                event == null ? '创建日程' : '编辑日程',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                      ),
                      if (mobile)
                        TextButton(
                          onPressed: busy ? null : save,
                          child: Text(
                            busy ? '保存中…' : '保存',
                            style: const TextStyle(fontSize: 17),
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(flex: 3, child: form),
                      if (!mobile) ...[
                        const VerticalDivider(width: 1),
                        Expanded(
                          flex: 2,
                          child: _draftPreview(
                            start,
                            end,
                            title.text,
                            event?['id'] as String?,
                            previewScroll,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!mobile) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => Navigator.pop(dialogContext),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: busy ? null : save,
                          child: Text(busy ? '保存中…' : '保存'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            );
            return Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              insetPadding: mobile ? EdgeInsets.zero : const EdgeInsets.all(28),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(mobile ? 0 : 10),
              ),
              child: SizedBox(
                width: 980,
                height: mobile ? double.infinity : 720,
                child: mobile ? SafeArea(child: content) : content,
              ),
            );
          },
        ),
      ),
    );
    await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    previewScroll.dispose();
    title.dispose();
    note.dispose();
    location.dispose();
  }

  Widget _draftPreview(
    DateTime start,
    DateTime end,
    String title,
    String? editingId,
    ScrollController scroll,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Text(
          '${start.month}月${start.day}日 · 当天安排',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: _timeline(
          [_day(start)],
          desktop: true,
          scrollController: scroll,
          allowEditing: false,
          previewEvents: [
            ..._onDay(
              start,
              filtered: false,
            ).where((e) => e['id'] != editingId),
            if (end.isAfter(start))
              {
                'id': 'draft-preview',
                '_draft': true,
                'title': title.isEmpty ? '未保存日程' : '草稿 · $title',
                'starts_at': start.toUtc().toIso8601String(),
                'ends_at': end.toUtc().toIso8601String(),
              },
          ]..sort((a, b) => str(a['starts_at']).compareTo(str(b['starts_at']))),
        ),
      ),
    ],
  );

  Widget _mobileTimeField(
    String label,
    DateTime time,
    VoidCallback? onTap,
  ) => Semantics(
    label: label,
    button: true,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              officeHourMinute(time, context: context),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${time.month}月${time.day}日 周${['日', '一', '二', '三', '四', '五', '六'][time.weekday % 7]}',
              style: const TextStyle(
                fontSize: 14,
                color: mutedColor,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _dateField(
    String label,
    String value,
    VoidCallback action, {
    required bool mobile,
    bool enabled = true,
  }) => InkWell(
    onTap: enabled ? action : null,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 20, color: mutedColor),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(fontSize: mobile ? 16 : 14, color: mutedColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: mobile ? 16 : 14)),
          ),
          const Icon(Icons.chevron_right, size: 18, color: mutedColor),
        ],
      ),
    ),
  );

  Future<void> _detail(Json initial) async {
    final identity = _CalendarIdentity(s);
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: s,
        builder: (_, _) => StatefulBuilder(
          builder: (context, change) {
            final event = identity.current(s)
                ? s.calendarEvents
                      .where((e) => e['id'] == initial['id'])
                      .firstOrNull
                : null;
            if (event == null) {
              return AlertDialog(
                title: const Text('日程已不可用'),
                content: const Text('当前身份已改变，或日程已被移除。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('关闭'),
                  ),
                ],
              );
            }
            final mobile = MediaQuery.sizeOf(context).width < 700;
            final attendees = (event['attendee_ids'] as List? ?? [])
                .map(str)
                .toList();
            final responses = event['responses'] is Map
                ? event['responses'] as Map
                : {};
            bool valid() =>
                mounted &&
                identity.current(s) &&
                s.calendarEvents.any((e) => e['id'] == initial['id']);
            return AlertDialog(
              title: Text(
                str(event['title']),
                style: const TextStyle(fontSize: 21),
              ),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${fullOfficeTime(event['starts_at'], context: context)}\n${fullOfficeTime(event['ends_at'], context: context)}',
                        style: TextStyle(
                          fontSize: mobile ? 16 : 14,
                          height: 1.7,
                          color: accentColor,
                        ),
                      ),
                      if (str(event['location']).isNotEmpty)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.location_on_outlined),
                          title: Text(str(event['location'])),
                        ),
                      if (str(event['description']).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            str(event['description']),
                            style: TextStyle(
                              fontSize: mobile ? 16 : 14,
                              height: 1.6,
                            ),
                          ),
                        ),
                      const Divider(height: 28),
                      Text(
                        '参与成员 · ${attendees.length}',
                        style: const TextStyle(fontSize: 15),
                      ),
                      ...attendees.map((id) {
                        final p =
                            s.principals
                                .where((p) => personId(p) == id)
                                .firstOrNull ??
                            {};
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: PersonAvatar(
                            name: str(p['name'], '工作成员'),
                            agent: p['kind'] == 'agent',
                            size: 36,
                          ),
                          title: Text(
                            '${str(p['name'], '工作成员')}${p['kind'] == 'agent' ? ' · Agent' : ''}',
                            style: TextStyle(fontSize: mobile ? 16 : 14),
                          ),
                          trailing: Text(
                            const {
                                  'accepted': '已接受',
                                  'declined': '已拒绝',
                                  'tentative': '待定',
                                }[responses[id]] ??
                                '未回应',
                            style: const TextStyle(
                              fontSize: 13,
                              color: mutedColor,
                            ),
                          ),
                        );
                      }),
                      if (attendees.contains(identity.principal)) ...[
                        const Divider(height: 28),
                        const Text(
                          '你的参与意向',
                          style: TextStyle(fontSize: 14, color: mutedColor),
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
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  selected:
                                      responses[identity.principal] == response,
                                  onSelected: busy
                                      ? null
                                      : (_) async {
                                          if (!valid() ||
                                              !s.calendarEvents.any(
                                                (e) =>
                                                    e['id'] == event['id'] &&
                                                    (e['attendee_ids']
                                                                as List? ??
                                                            [])
                                                        .contains(
                                                          identity.principal,
                                                        ),
                                              )) {
                                            return;
                                          }
                                          change(() => busy = true);
                                          try {
                                            await s.respondCalendarEvent(
                                              str(event['id']),
                                              response,
                                            );
                                          } catch (e) {
                                            if (context.mounted && valid()) {
                                              notifyOffice(
                                                context,
                                                friendlyError(e),
                                              );
                                            }
                                          } finally {
                                            if (context.mounted && valid()) {
                                              change(() => busy = false);
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
                if (_canEdit(event))
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            if (!valid() || !_canEdit(event)) return;
                            Navigator.pop(dialogContext);
                            _edit(event);
                          },
                    child: const Text('编辑日程'),
                  ),
                if (event['meeting_id'] != null)
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () {
                            if (!valid() ||
                                !s.calendarEvents.any(
                                  (e) =>
                                      e['id'] == event['id'] &&
                                      e['meeting_id'] == event['meeting_id'],
                                )) {
                              return;
                            }
                            Navigator.pop(dialogContext);
                            widget.onMeeting(str(event['meeting_id']));
                          },
                    child: const Text('加入会议'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _search() async {
    final identity = _CalendarIdentity(s);
    var query = '';
    final event = await showDialog<Json>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: s,
        builder: (_, _) => StatefulBuilder(
          builder: (context, change) => AlertDialog(
            title: const Text('搜索日程'),
            content: SizedBox(
              width: 450,
              height: 380,
              child: !identity.current(s)
                  ? const Text('当前身份已改变，请重新搜索。')
                  : Column(
                      children: [
                        TextField(
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: '主题、描述或地点',
                            prefixIcon: Icon(Icons.search),
                          ),
                          onChanged: (value) =>
                              change(() => query = value.trim().toLowerCase()),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: ListView(
                            children: s.calendarEvents
                                .where(
                                  (e) =>
                                      ['title', 'description', 'location'].any(
                                        (field) =>
                                            str(e[field])
                                                .toLowerCase()
                                                .contains(query),
                                      ),
                                )
                                .map(
                                  (e) => ListTile(
                                    title: Text(str(e['title'])),
                                    subtitle: Text(
                                      fullOfficeTime(
                                        e['starts_at'],
                                        context: context,
                                      ),
                                    ),
                                    onTap: () {
                                      if (identity.current(s)) {
                                        Navigator.pop(dialogContext, e);
                                      }
                                    },
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
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      ),
    );
    if (event != null && mounted && identity.current(s)) await _detail(event);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: s,
    builder: (_, _) => LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth > 650;
        _hourHeight = desktop ? 48 : 52;
        final view =
            _chosenView ??
            (desktop ? _CalendarView.week : _CalendarView.threeDay);
        _view = view;
        return Material(
          color: Colors.white,
          child: Column(
            children: [
              if (desktop)
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '日历',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () => _edit(),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text(
                          '创建日程',
                          style: TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                )
              else
                _mobileHeader(),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  children: [
                    if (constraints.maxWidth > 790) _miniMonth(),
                    Expanded(
                      child: Column(
                        children: [
                          if (desktop) _toolbar(),
                          if (!desktop && _monthExpanded) _inlineMonth(),
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: view == _CalendarView.month
                                      ? _monthGrid(desktop)
                                      : _timeline(
                                          view == _CalendarView.day
                                              ? [_day(_selected)]
                                              : view == _CalendarView.threeDay
                                              ? List.generate(
                                                  3,
                                                  (i) => DateTime(
                                                    _selected.year,
                                                    _selected.month,
                                                    _selected.day + i,
                                                  ),
                                                )
                                              : List.generate(
                                                  7,
                                                  (i) => DateTime(
                                                    _sunday.year,
                                                    _sunday.month,
                                                    _sunday.day + i,
                                                  ),
                                                ),
                                          desktop: desktop,
                                        ),
                                ),
                                if (!desktop)
                                  Positioned(
                                    right: 22,
                                    bottom: 18,
                                    child: FloatingActionButton(
                                      key: const ValueKey(
                                        'calendar-mobile-create',
                                      ),
                                      heroTag: 'calendar-create',
                                      onPressed: () => _edit(),
                                      backgroundColor: const Color(0xff1456f0),
                                      foregroundColor: Colors.white,
                                      shape: const CircleBorder(),
                                      tooltip: '创建日程',
                                      child: const Icon(Icons.add, size: 30),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Widget _mobileHeader() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 2),
        child: Row(
          children: [
            widget.mobileHeaderLeading ??
                PersonAvatar(
                  name: str(s.me?['name']),
                  agent: s.me?['kind'] == 'agent',
                  size: 36,
                ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                key: const ValueKey('calendar-month-toggle'),
                onTap: () => setState(() => _monthExpanded = !_monthExpanded),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${_selected.year}年${_selected.month}月',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _monthExpanded
                          ? Icons.arrow_drop_up
                          : Icons.arrow_drop_down,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: _search,
              tooltip: '搜索日程',
              icon: const Icon(Icons.search, size: 27),
            ),
          ],
        ),
      ),
      if (!_monthExpanded)
        Padding(
          padding: const EdgeInsets.only(left: 24, right: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: accentColor, width: 2),
                  ),
                ),
                child: const Text(
                  '日历',
                  style: TextStyle(fontSize: 14, color: accentColor),
                ),
              ),
              const Spacer(),
              PopupMenuButton<_CalendarView>(
                key: const ValueKey('calendar-mobile-view-menu'),
                tooltip: '切换日历视图',
                icon: const Icon(
                  Icons.calendar_view_week_outlined,
                  size: 21,
                  color: mutedColor,
                ),
                initialValue: _view,
                onSelected: (value) => setState(() => _chosenView = value),
                itemBuilder: (_) => [
                  ..._CalendarView.values.map(
                    (v) => PopupMenuItem(
                      value: v,
                      child: Text(
                        _viewName(v),
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem<_CalendarView>(
                    key: const ValueKey('calendar-return-today'),
                    onTap: _today,
                    child: const Text('回到今天', style: TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
  String _viewName(_CalendarView view) => const {
    _CalendarView.day: '日',
    _CalendarView.threeDay: '三日',
    _CalendarView.week: '周',
    _CalendarView.month: '月',
  }[view]!;
  Widget _toolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
    child: Row(
      children: [
        OutlinedButton(onPressed: _today, child: const Text('今天')),
        IconButton(
          onPressed: () => _step(-1),
          tooltip: '上一个日期范围',
          icon: const Icon(Icons.chevron_left, size: 20),
        ),
        IconButton(
          onPressed: () => _step(1),
          tooltip: '下一个日期范围',
          icon: const Icon(Icons.chevron_right, size: 20),
        ),
        Expanded(
          child: Text(
            _dateTitle(),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          key: const ValueKey('calendar-view-selector'),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children:
                [_CalendarView.day, _CalendarView.week, _CalendarView.month]
                    .map(
                      (view) => InkWell(
                        key: ValueKey('calendar-view-${view.name}'),
                        onTap: () => setState(() => _chosenView = view),
                        child: Container(
                          width: 60,
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _view == view
                                ? const Color(0xffe8efff)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            _viewName(view),
                            style: TextStyle(
                              fontSize: 14,
                              color: _view == view ? accentColor : inkColor,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
          ),
        ),
      ],
    ),
  );

  Widget _inlineMonth() => Container(
    key: const ValueKey('calendar-inline-month'),
    decoration: const BoxDecoration(
      color: Colors.white,
      boxShadow: [
        BoxShadow(
          color: Color(0x15000000),
          blurRadius: 5,
          offset: Offset(0, 3),
        ),
      ],
    ),
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${_selected.year}年${_selected.month}月',
                style: const TextStyle(fontSize: 15),
              ),
            ),
            IconButton(
              onPressed: () => setState(
                () => _selected = DateTime(
                  _selected.year,
                  _selected.month - 1,
                  1,
                ),
              ),
              tooltip: '上个月',
              icon: const Icon(Icons.chevron_left, size: 20),
            ),
            IconButton(
              onPressed: () => setState(
                () => _selected = DateTime(
                  _selected.year,
                  _selected.month + 1,
                  1,
                ),
              ),
              tooltip: '下个月',
              icon: const Icon(Icons.chevron_right, size: 20),
            ),
          ],
        ),
        _monthDates(mobile: true),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => setState(() => _monthExpanded = false),
          child: const Icon(
            Icons.keyboard_arrow_up,
            color: mutedColor,
            size: 24,
          ),
        ),
      ],
    ),
  );

  Widget _monthDates({required bool mobile}) {
    final first = DateTime(_selected.year, _selected.month, 1);
    final start = DateTime(first.year, first.month, 1 - first.weekday % 7);
    return Column(
      children: [
        Row(
          children: ['日', '一', '二', '三', '四', '五', '六']
              .map(
                (d) => Expanded(
                  child: Center(
                    child: Text(
                      d,
                      style: TextStyle(
                        fontSize: mobile ? 13 : 12,
                        color: mutedColor,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisExtent: mobile ? 37 : 34,
          ),
          itemCount: 42,
          itemBuilder: (_, i) {
            final date = DateTime(start.year, start.month, start.day + i);
            final today = _day(date) == _day(DateTime.now()),
                selected = _day(date) == _day(_selected);
            return InkWell(
              key: ValueKey(
                'calendar-date-${date.year}-${date.month}-${date.day}',
              ),
              onTap: () => setState(() => _selected = date),
              child: Center(
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? (mobile ? accentColor : const Color(0xffe6edfc))
                        : Colors.transparent,
                    shape: BoxShape.circle,
                    border: today && !mobile
                        ? Border.all(color: accentColor)
                        : null,
                  ),
                  child: Text(
                    '${date.day}',
                    style: TextStyle(
                      fontSize: mobile ? 16 : 14,
                      color: selected && mobile
                          ? Colors.white
                          : today
                          ? accentColor
                          : date.month == _selected.month
                          ? inkColor
                          : mutedColor,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _miniMonth() {
    final rooms = officeBusinessRooms(s).where(
      (r) =>
          str(r['name']).toLowerCase().contains(_calendarQuery.toLowerCase()),
    );
    return SizedBox(
      width: 240,
      child: Material(
        color: const Color(0xfff6f7f8),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_selected.year}年${_selected.month}月',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(
                    () => _selected = DateTime(
                      _selected.year,
                      _selected.month - 1,
                      1,
                    ),
                  ),
                  tooltip: '上个月',
                  icon: const Icon(Icons.chevron_left, size: 18),
                ),
                IconButton(
                  onPressed: () => setState(
                    () => _selected = DateTime(
                      _selected.year,
                      _selected.month + 1,
                      1,
                    ),
                  ),
                  tooltip: '下个月',
                  icon: const Icon(Icons.chevron_right, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _monthDates(mobile: false),
            const SizedBox(height: 24),
            TextField(
              decoration: const InputDecoration(
                hintText: '搜索工作会话日历',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (value) => setState(() => _calendarQuery = value),
            ),
            const SizedBox(height: 20),
            const Text(
              '我的日程',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            CheckboxListTile(
              value: _onlyMine,
              onChanged: (v) => setState(() => _onlyMine = v == true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('仅我参与的日程', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 12),
            const Text(
              '工作会话日历',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            ...rooms.map(
              (room) => CheckboxListTile(
                key: ValueKey('calendar-room-${room['id']}'),
                value: !_hiddenRooms.contains(str(room['id'])),
                onChanged: (v) => setState(() {
                  v == true
                      ? _hiddenRooms.remove(str(room['id']))
                      : _hiddenRooms.add(str(room['id']));
                }),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  str(room['name']),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _monthGrid(bool desktop) {
    final first = DateTime(_selected.year, _selected.month, 1);
    final start = DateTime(first.year, first.month, 1 - first.weekday % 7);
    return Column(
      children: [
        SizedBox(
          height: 35,
          child: Row(
            children: ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: TextStyle(
                          fontSize: desktop ? 13 : 14,
                          color: mutedColor,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (_, bounds) => SingleChildScrollView(
              child: SizedBox(
                height: math.max(bounds.maxHeight, desktop ? 510 : 570),
                child: Column(
                  children: List.generate(
                    6,
                    (week) => Expanded(
                      child: Row(
                        children: List.generate(7, (weekday) {
                          final date = DateTime(
                            start.year,
                            start.month,
                            start.day + week * 7 + weekday,
                          );
                          final events = _onDay(date),
                              today = _day(date) == _day(DateTime.now());
                          return Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: date.month == _selected.month
                                    ? Colors.white
                                    : const Color(0xfffafafa),
                                border: const Border(
                                  top: BorderSide(color: borderColor),
                                  left: BorderSide(color: borderColor),
                                ),
                              ),
                              child: LayoutBuilder(
                                builder: (context, cell) {
                                  final scaler = MediaQuery.textScalerOf(
                                    context,
                                  );
                                  final dayFont = desktop ? 14.0 : 16.0;
                                  final eventFont = desktop ? 12.0 : 11.0;
                                  final dayHeight =
                                      scaler.scale(dayFont) * 1.2 + 12;
                                  final eventHeight =
                                      scaler.scale(eventFont) * 1.2 + 6;
                                  final moreHeight = scaler.scale(12) * 1.2 + 4;
                                  final available = math.max(
                                    0.0,
                                    cell.maxHeight - dayHeight,
                                  );
                                  var shown = math.min(
                                    events.length,
                                    (available / (eventHeight + 3)).floor(),
                                  );
                                  if (shown < events.length) {
                                    shown = math.max(
                                      0,
                                      ((available - moreHeight) /
                                              (eventHeight + 3))
                                          .floor(),
                                    );
                                  }
                                  void openDay() => setState(() {
                                    _selected = date;
                                    _chosenView = _CalendarView.day;
                                  });
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      SizedBox(
                                        height: dayHeight,
                                        child: InkWell(
                                          key: ValueKey(
                                            'calendar-month-open-${date.year}-${date.month}-${date.day}',
                                          ),
                                          onTap: openDay,
                                          child: Center(
                                            child: Text(
                                              '${date.day}',
                                              style: TextStyle(
                                                fontSize: dayFont,
                                                height: 1.2,
                                                color: today
                                                    ? accentColor
                                                    : date.month ==
                                                          _selected.month
                                                    ? inkColor
                                                    : mutedColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      ...events
                                          .take(shown)
                                          .map(
                                            (event) => Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    2,
                                                    0,
                                                    2,
                                                    3,
                                                  ),
                                              child: InkWell(
                                                key: ValueKey(
                                                  'calendar-month-event-${event['id']}-${date.day}',
                                                ),
                                                onTap: () => _detail(event),
                                                child: Container(
                                                  height: eventHeight,
                                                  color: const Color(
                                                    0xffe8efff,
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 3,
                                                      ),
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Text(
                                                    str(event['title']),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: eventFont,
                                                      height: 1.2,
                                                      color: const Color(
                                                        0xff3766bc,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      if (shown < events.length)
                                        SizedBox(
                                          height: math.min(
                                            moreHeight,
                                            available,
                                          ),
                                          child: Semantics(
                                            label:
                                                '还有${events.length - shown}个日程，查看当天',
                                            button: true,
                                            child: InkWell(
                                              key: ValueKey(
                                                'calendar-month-more-${date.year}-${date.month}-${date.day}',
                                              ),
                                              onTap: openDay,
                                              child: Center(
                                                child: Text(
                                                  '+${events.length - shown}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    height: 1.2,
                                                    color: mutedColor,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _timeline(
    List<DateTime> days, {
    required bool desktop,
    ScrollController? scrollController,
    List<Json>? previewEvents,
    bool allowEditing = true,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final hourHeight = desktop ? 48.0 : 52.0;
      final axisWidth = desktop ? 54.0 : 44.0;
      final totalWidth = math.max(
        constraints.maxWidth,
        days.length == 7 && !desktop ? 560.0 : 0.0,
      );
      final width = (totalWidth - axisWidth) / days.length;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: Column(
            children: [
              SizedBox(
                height: math.max(
                  desktop ? 65 : 60,
                  MediaQuery.textScalerOf(context).scale(desktop ? 33 : 34) *
                          1.2 +
                      12,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: axisWidth,
                      child: Center(
                        child: Text(
                          _zoneLabel(_selected),
                          style: const TextStyle(
                            fontSize: 9,
                            color: mutedColor,
                          ),
                        ),
                      ),
                    ),
                    ...days.map(
                      (day) => SizedBox(
                        width: width,
                        child: InkWell(
                          onTap: allowEditing
                              ? () => setState(() => _selected = day)
                              : null,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '周${['日', '一', '二', '三', '四', '五', '六'][day.weekday % 7]}',
                                style: TextStyle(
                                  fontSize: desktop ? 13 : 12,
                                  height: 1.2,
                                  color: mutedColor,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                '${day.day}',
                                style: TextStyle(
                                  fontSize: desktop ? 18 : 22,
                                  height: 1.2,
                                  color: _day(day) == _day(DateTime.now())
                                      ? accentColor
                                      : inkColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: ValueKey(
                    allowEditing
                        ? 'calendar-timeline-scroll'
                        : 'calendar-draft-timeline-scroll',
                  ),
                  controller: scrollController ?? _timelineScroll,
                  child: SizedBox(
                    height: 24 * hourHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: axisWidth,
                          child: Column(
                            children: List.generate(
                              24,
                              (hour) => SizedBox(
                                height: hourHeight,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Text(
                                    '${hour.toString().padLeft(2, '0')}:00',
                                    style: TextStyle(
                                      fontSize: desktop ? 10 : 11,
                                      color: mutedColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        ...days.map(
                          (day) => _dayColumn(
                            day,
                            width,
                            hourHeight,
                            desktop,
                            entries: previewEvents,
                            allowEditing: allowEditing,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _dayColumn(
    DateTime day,
    double width,
    double hourHeight,
    bool desktop, {
    List<Json>? entries,
    bool allowEditing = true,
  }) {
    final events = entries ?? _onDay(day), lanes = <int>[], counts = <int>[];
    final laneEnds = <DateTime>[];
    var groupStart = 0;
    DateTime? groupEnd;
    void finishGroup() {
      final count = math.max(1, laneEnds.length);
      for (var i = groupStart; i < lanes.length; i++) {
        counts.add(count);
      }
      groupStart = lanes.length;
      laneEnds.clear();
    }

    for (final event in events) {
      final start = _time(event['starts_at'])!, end = _time(event['ends_at'])!;
      if (groupEnd != null && !start.isBefore(groupEnd)) finishGroup();
      var lane = laneEnds.indexWhere((value) => !value.isAfter(start));
      if (lane < 0) {
        lane = laneEnds.length;
        laneEnds.add(end);
      } else {
        laneEnds[lane] = end;
      }
      lanes.add(lane);
      groupEnd = groupEnd == null || end.isAfter(groupEnd) ? end : groupEnd;
    }
    finishGroup();
    final now = DateTime.now();
    return SizedBox(
      width: width,
      child: Stack(
        children: [
          Column(
            children: List.generate(
              24,
              (hour) => InkWell(
                key: ValueKey(
                  '${allowEditing ? 'calendar-slot' : 'calendar-preview-slot'}-${day.year}-${day.month}-${day.day}-$hour',
                ),
                onTap: allowEditing
                    ? () => _edit(
                        null,
                        DateTime(day.year, day.month, day.day, hour),
                      )
                    : null,
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
          ...List.generate(events.length, (i) {
            final event = events[i],
                start = _time(event['starts_at'])!,
                end = _time(event['ends_at'])!;
            // A calendar grid represents wall-clock hours, including DST days.
            final top =
                (_day(start).isBefore(_day(day))
                    ? 0
                    : start.hour * 60 + start.minute) /
                60 *
                hourHeight;
            final bottom =
                (_day(end).isAfter(_day(day))
                    ? 1440
                    : end.hour * 60 + end.minute) /
                60 *
                hourHeight;
            final count = counts[i];
            final height = math.min(
              math.max(22.0, bottom - top),
              24 * hourHeight - top,
            );
            if (height <= 0) return const SizedBox();
            return Positioned(
              top: top,
              left: 2 + lanes[i] * (width - 4) / count,
              width: math.max(1, (width - 4) / count - 2),
              height: height,
              child: InkWell(
                key: ValueKey(
                  '${allowEditing ? 'calendar-event' : 'calendar-preview-event'}-${event['id']}-${day.day}',
                ),
                onTap: allowEditing ? () => _detail(event) : null,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xffe8efff),
                    borderRadius: BorderRadius.circular(3),
                    border: const Border(
                      left: BorderSide(color: Color(0xff7895f5), width: 3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          str(event['title']),
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            fontSize: desktop ? 12 : 13,
                            color: const Color(0xff3766bc),
                            height: 1.3,
                          ),
                        ),
                      ),
                      if (height > 45)
                        Text(
                          '${officeHourMinute(start, context: context)} – ${officeHourMinute(end, context: context)}',
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xff7c97c9),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
          if (_day(day) == _day(now))
            Positioned(
              top: (now.hour + now.minute / 60) * hourHeight,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Container(height: 1, color: const Color(0xffed5b5b)),
              ),
            ),
        ],
      ),
    );
  }
}
