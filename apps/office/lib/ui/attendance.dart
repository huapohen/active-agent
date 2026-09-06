import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeAttendance extends StatefulWidget {
  const OfficeAttendance({super.key, required this.state});
  final OfficeState state;
  @override
  State<OfficeAttendance> createState() => _OfficeAttendanceState();
}

class _OfficeAttendanceState extends State<OfficeAttendance> {
  final _location = TextEditingController();
  bool _busy = false;
  String? _error, _date;
  late String? _roomId = widget.state.selectedRoomId;
  OfficeState get s => widget.state;
  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  Future<void> _clock(bool checkIn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _roomId ??= await chooseOfficeRoom(context, s);
      if (_roomId == null) return;
      await s.loadAttendance();
      _date = null;
      if (checkIn) {
        await s.checkIn(locationNote: _location.text.trim(), roomId: _roomId);
      } else {
        await s.checkOut(locationNote: _location.text.trim(), roomId: _roomId);
      }
      if (mounted) {
        _location.clear();
        notifyOffice(context, checkIn ? '上班打卡已记录' : '下班打卡已记录');
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_date ?? '') ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null) return;
    _date =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    try {
      await s.loadAttendance(date: _date);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().toUtc().add(const Duration(hours: 8));
    final todayKey =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final current =
        s.attendanceRecords
            .where(
              (r) =>
                  r['date'] == todayKey &&
                  r['room_id'] == _roomId &&
                  r['principal_id'] == personId(s.me ?? {}),
            )
            .firstOrNull ??
        <String, dynamic>{};
    final records = s.attendanceRecords;
    return Column(
      children: [
        BusinessHeader(
          title: '考勤',
          subtitle: '每一次工作到场，都有可查记录',
          actions: [
            IconButton(
              tooltip: '刷新考勤',
              onPressed: _busy
                  ? null
                  : () async {
                      try {
                        await s.loadAttendance(date: _date);
                      } catch (e) {
                        if (mounted) setState(() => _error = friendlyError(e));
                      }
                    },
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              BusinessCard(
                color: const Color(0xfff6f8ff),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        PersonAvatar(
                          name: str(s.me?['name']),
                          agent: s.me?['kind'] == 'agent',
                          size: 40,
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                str(s.me?['name']),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                str(current['date'], '今日考勤'),
                                style: const TextStyle(
                                  color: mutedColor,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 25),
                    Text(
                      '工作会话：${_roomId == null ? '尚未选择' : officeRoomName(s, _roomId)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 5),
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () async {
                              try {
                                final id = await chooseOfficeRoom(context, s);
                                if (id != null) {
                                  setState(() => _roomId = id);
                                  await s.loadAttendance(date: _date);
                                }
                              } catch (e) {
                                if (mounted) {
                                  setState(() => _error = friendlyError(e));
                                }
                              }
                            },
                      icon: const Icon(Icons.swap_horiz, size: 16),
                      label: const Text('切换工作会话'),
                    ),
                    const SizedBox(height: 13),
                    TextField(
                      controller: _location,
                      maxLength: 300,
                      decoration: const InputDecoration(
                        labelText: '地点备注（选填）',
                        hintText: '例如：办公室、居家办公',
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy || current['check_in_at'] != null
                              ? null
                              : () => _clock(true),
                          icon: const Icon(Icons.login, size: 18),
                          label: const Text('上班打卡'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy || current['check_out_at'] != null
                              ? null
                              : () => _clock(false),
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('下班打卡'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    const Text(
                      '打卡时间以服务器记录为准。地点为你填写的备注。',
                      style: TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        height: 1.7,
                      ),
                    ),
                    if (current['server_time'] != null)
                      Text(
                        '服务器时间：${fullOfficeTime(current['server_time'], context: context)}',
                        style: const TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    BusinessError(_error),
                    if (_busy) const LinearProgressIndicator(minHeight: 2),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '打卡记录',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _loadDate,
                    icon: const Icon(Icons.calendar_today_outlined, size: 15),
                    label: Text(_date ?? '选择日期'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (records.isEmpty)
                const BusinessCard(
                  child: Text(
                    '所选日期还没有打卡记录。',
                    style: TextStyle(color: mutedColor),
                  ),
                )
              else
                ...records.map(
                  (record) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: BusinessCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.fact_check_outlined,
                                size: 21,
                                color: accentColor,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  str(record['date']),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                'r${record['revision']}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: mutedColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text(
                            '上班  ${fullOfficeTime(record['check_in_at'], context: context)}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          if (str(record['check_in_note']).isNotEmpty)
                            Text(
                              str(record['check_in_note']),
                              style: const TextStyle(
                                fontSize: 11,
                                color: mutedColor,
                              ),
                            ),
                          const SizedBox(height: 9),
                          Text(
                            '下班  ${fullOfficeTime(record['check_out_at'], context: context)}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          if (str(record['check_out_note']).isNotEmpty)
                            Text(
                              str(record['check_out_note']),
                              style: const TextStyle(
                                fontSize: 11,
                                color: mutedColor,
                              ),
                            ),
                          const SizedBox(height: 9),
                          Text(
                            str(
                              s.rooms
                                  .where((r) => r['id'] == record['room_id'])
                                  .firstOrNull?['name'],
                              '工作会话',
                            ),
                            style: const TextStyle(
                              fontSize: 11,
                              color: mutedColor,
                            ),
                          ),
                          if (maps(record['audit']).isNotEmpty)
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text(
                                '查看打卡与更正历史',
                                style: TextStyle(fontSize: 11),
                              ),
                              children: maps(record['audit'])
                                  .map(
                                    (entry) => Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          '${fullOfficeTime(entry['at'], context: context)} · ${const {'check_in': '上班打卡', 'check_out': '下班打卡', 'approved_correction': '审批通过更正'}[entry['action']] ?? str(entry['action'])} ${str(entry['reason'])}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: mutedColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
