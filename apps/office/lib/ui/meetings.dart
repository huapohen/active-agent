import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import '../meeting_controller.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeMeetings extends StatefulWidget {
  const OfficeMeetings({
    super.key,
    required this.state,
    required this.media,
    required this.onCalendar,
  });
  final OfficeState state;
  final MeetingMediaController media;
  final VoidCallback onCalendar;
  @override
  State<OfficeMeetings> createState() => OfficeMeetingsState();
}

class OfficeMeetingsState extends State<OfficeMeetings> {
  Future<void> createMeeting() => _create();
  Future<void> joinMeeting() => _joinPreview();
  bool _history = false, _busy = false;
  String _query = '';
  OfficeState get s => widget.state;
  MeetingMediaController get media => widget.media;
  Future<void> _join(String id) async {
    setState(() => _busy = true);
    try {
      await media.join(s, id.trim());
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinPreview([String? initial]) async {
    final controller = TextEditingController(text: initial ?? '');
    await showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 13, 20, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                    ),
                    const Spacer(),
                    const Text(
                      '加入会议',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 40),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 450),
                    child: Padding(
                      padding: const EdgeInsets.all(30),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextField(
                            controller: controller,
                            decoration: const InputDecoration(
                              labelText: '会议 ID',
                              hintText: '输入或粘贴会议 ID',
                            ),
                            autocorrect: false,
                          ),
                          const SizedBox(height: 55),
                          PersonAvatar(
                            name: str(s.me?['name']),
                            agent: s.me?['kind'] == 'agent',
                            size: 110,
                          ),
                          const SizedBox(height: 15),
                          Text(
                            str(s.me?['name']),
                            style: const TextStyle(fontSize: 17),
                          ),
                          const SizedBox(height: 42),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _JoinStatus(
                                icon: Icons.mic_off_outlined,
                                label: '麦克风已关闭',
                              ),
                              SizedBox(width: 35),
                              _JoinStatus(
                                icon: Icons.videocam_off_outlined,
                                label: '摄像头已关闭',
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            '先进入会议，再由你开启麦克风、摄像头或屏幕共享。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: mutedColor,
                              height: 1.8,
                            ),
                          ),
                          const SizedBox(height: 42),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: () {
                                if (controller.text.trim().isNotEmpty) {
                                  Navigator.pop(
                                    dialogContext,
                                    controller.text.trim(),
                                  );
                                }
                              },
                              child: const Text('加入会议'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((id) async {
      if (id is String && id.isNotEmpty) await _join(id);
    });
    controller.dispose();
  }

  Future<void> _create({bool scheduled = false}) async {
    final roomId = s.selectedRoomId ?? await chooseOfficeRoom(context, s);
    if (roomId == null || !mounted) return;
    final documents = officeRoomDocuments(s, roomId);
    final title = TextEditingController(
      text: scheduled ? '' : '${str(s.me?['name'])} 的会议',
    );
    var starts = DateTime.now().add(const Duration(hours: 1));
    var duration = 30, busy = false;
    String? documentId;
    String? error;
    final meeting = await showDialog<Json>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text(
            scheduled ? '预约会议' : '发起会议',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '会议主题',
                      hintText: '给这次讨论起个名字',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '会话：${officeRoomName(s, roomId)}',
                    style: const TextStyle(fontSize: 11, color: mutedColor),
                  ),
                  if (scheduled) ...[
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: starts,
                          firstDate: DateTime.now().subtract(
                            const Duration(days: 1),
                          ),
                          lastDate: DateTime.now().add(
                            const Duration(days: 730),
                          ),
                        );
                        if (date == null || !context.mounted) return;
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(starts),
                        );
                        if (time != null) {
                          change(
                            () => starts = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              time.hour,
                              time.minute,
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.schedule_outlined, size: 18),
                      label: Text(
                        clockText(starts.toIso8601String(), date: true),
                      ),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<int>(
                      initialValue: duration,
                      decoration: const InputDecoration(labelText: '预计时长'),
                      items: [15, 30, 45, 60, 90, 120]
                          .map(
                            (m) => DropdownMenuItem(
                              value: m,
                              child: Text('$m 分钟'),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => duration = v ?? 30,
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (documents.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      initialValue: '',
                      decoration: const InputDecoration(labelText: '关联会议文档'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('暂不关联')),
                        ...documents.map(
                          (doc) => DropdownMenuItem(
                            value: str(doc['id']),
                            child: Text(
                              str(doc['title']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (id) =>
                          documentId = id?.isEmpty == true ? null : id,
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Text(
                    '会议资料与日程留在工作会话中。音视频默认关闭，由每位参与者自行开启。',
                    style: TextStyle(
                      fontSize: 11,
                      color: mutedColor,
                      height: 1.8,
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
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
                      if (title.text.trim().isEmpty) {
                        change(() => error = '请填写会议主题');
                        return;
                      }
                      change(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final result = await s.createMeeting(
                          roomId: roomId,
                          title: title.text.trim(),
                          startsAt: scheduled
                              ? starts.toUtc().toIso8601String()
                              : null,
                          durationMinutes: duration,
                          documentId: documentId,
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, result);
                        }
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
                    ? '正在创建…'
                    : scheduled
                    ? '预约会议'
                    : '发起并加入',
              ),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    if (meeting != null) {
      if (scheduled) {
        if (mounted) notifyOffice(context, '会议已预约，工作会话成员可查看与加入。');
      } else {
        await _join(str(meeting['id']));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: media,
    builder: (context, _) {
      if (media.activeMeeting != null) {
        return MeetingRoom(state: s, media: media);
      }
      final meetings = s.meetings
          .where(
            (m) =>
                (_history ? m['status'] == 'ended' : m['status'] != 'ended') &&
                str(m['title']).toLowerCase().contains(_query.toLowerCase()),
          )
          .toList();
      return ListView(
        padding: const EdgeInsets.all(25),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '视频会议',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(
                width: MediaQuery.sizeOf(context).width < 700 ? 125 : 190,
                child: OfficeSearch(
                  hint: '搜索会议',
                  onChanged: (q) => setState(() => _query = q),
                ),
              ),
            ],
          ),
          const SizedBox(height: 29),
          if (media.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                media.error,
                style: const TextStyle(fontSize: 12, color: Colors.redAccent),
              ),
            ),
          Row(
            children: [
              _entry(
                Icons.videocam_outlined,
                '发起会议',
                const Color(0xff4d89ec),
                _busy ? null : () => _create(),
              ),
              _entry(
                Icons.add_box_outlined,
                '加入会议',
                const Color(0xff4d89ec),
                _busy ? null : () => _joinPreview(),
              ),
              _entry(
                Icons.calendar_today_outlined,
                '预约会议',
                const Color(0xff4d89ec),
                _busy ? null : () => _create(scheduled: true),
              ),
              _entry(
                Icons.history,
                '会议记录',
                const Color(0xff837fd7),
                () => setState(() => _history = true),
              ),
            ],
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _history = false),
                child: Text(
                  '即将开始',
                  style: TextStyle(
                    fontWeight: !_history ? FontWeight.w600 : FontWeight.w400,
                    color: !_history ? accentColor : mutedColor,
                  ),
                ),
              ),
              const SizedBox(width: 15),
              TextButton(
                onPressed: () => setState(() => _history = true),
                child: Text(
                  '历史会议',
                  style: TextStyle(
                    fontWeight: _history ? FontWeight.w600 : FontWeight.w400,
                    color: _history ? accentColor : mutedColor,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: widget.onCalendar,
                tooltip: '查看日历',
                icon: const Icon(Icons.calendar_month_outlined, size: 19),
              ),
            ],
          ),
          const Divider(height: 1),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (meetings.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: EmptyOffice(
                title: _history ? '还没有历史会议' : '暂无即将开始的会议',
                subtitle: _history
                    ? '已结束会议的主题、参与者与关联资料会保留在这里。'
                    : '发起一场讨论，或预约一个共同推进的时间。',
                icon: Icons.video_camera_front_outlined,
              ),
            ),
          ...meetings.map(
            (meeting) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 17),
              child: Row(
                children: [
                  Container(
                    width: 76,
                    height: 58,
                    decoration: BoxDecoration(
                      color: _history
                          ? const Color(0xfff1f2f6)
                          : const Color(0xffedf3ff),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(
                      _history
                          ? Icons.groups_outlined
                          : Icons.videocam_outlined,
                      color: _history ? const Color(0xffb0b7c7) : accentColor,
                      size: 29,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          str(meeting['title']),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          '${clockText(meeting['starts_at'] ?? meeting['created_at'], date: true)} · ${meeting['duration_minutes'] ?? 30} 分钟',
                          style: const TextStyle(
                            fontSize: 10,
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          meeting['status'] == 'active'
                              ? '进行中'
                              : meeting['status'] == 'ended'
                              ? '已结束'
                              : '已预约',
                          style: TextStyle(
                            fontSize: 10,
                            color: meeting['status'] == 'active'
                                ? const Color(0xff35a97b)
                                : mutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!_history)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _joinPreview(str(meeting['id'])),
                      child: const Text('加入'),
                    )
                  else
                    IconButton(
                      onPressed: () async {
                        try {
                          final details = await s.meetingDetail(
                            str(meeting['id']),
                          );
                          if (!context.mounted) return;
                          final participants = maps(details['participants']);
                          await showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(
                                str(meeting['title']),
                                style: const TextStyle(fontSize: 18),
                              ),
                              content: SizedBox(
                                width: 400,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '会议 ID：${str(meeting['id'])}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: mutedColor,
                                      ),
                                    ),
                                    const SizedBox(height: 17),
                                    Text(
                                      '参与成员：${participants.map((p) => str(p['name'])).toSet().join('、')}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    const SizedBox(height: 12),
                                    const Text(
                                      '音视频未被录制；这里保留会议和参与记录。',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: mutedColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          );
                        } catch (e) {
                          if (context.mounted) {
                            notifyOffice(context, friendlyError(e));
                          }
                        }
                      },
                      tooltip: '查看会议记录',
                      icon: const Icon(Icons.chevron_right, size: 20),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
  Widget _entry(
    IconData icon,
    String name,
    Color color,
    VoidCallback? action,
  ) => Expanded(
    child: InkWell(
      onTap: action,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Container(
              width: 45,
              height: 45,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 24, color: Colors.white),
            ),
            const SizedBox(height: 12),
            Text(name, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    ),
  );
}

class _JoinStatus extends StatelessWidget {
  const _JoinStatus({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: Color(0xfff1f3f7),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 23, color: mutedColor),
      ),
      const SizedBox(height: 10),
      Text(label, style: const TextStyle(fontSize: 10, color: mutedColor)),
    ],
  );
}

class MeetingRoom extends StatelessWidget {
  const MeetingRoom({super.key, required this.state, required this.media});
  final OfficeState state;
  final MeetingMediaController media;
  Future<void> _notes(BuildContext context) async {
    try {
      final details = await state.meetingDetail(
        str(media.activeMeeting?['id']),
      );
      final meeting = Map<String, dynamic>.from(details['meeting']);
      final roomId = str(meeting['room_id']);
      if (!context.mounted) return;
      var documents = officeRoomDocuments(state, roomId);
      final reference =
          details['notes_document_current'] ?? meeting['notes_document'];
      if (reference is Map) {
        await OfficeDialogs.document(context, state, {
          'id': reference['id'],
          'room_id': roomId,
        });
        return;
      }
      if (documents.isEmpty) {
        await OfficeDialogs.document(context, state, {'room_id': roomId});
        if (!context.mounted) return;
        documents = officeRoomDocuments(state, roomId);
        if (documents.isEmpty) return;
      }
      final selected = await showDialog<Json>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('关联共同纪要文档', style: TextStyle(fontSize: 18)),
          children: documents
              .map(
                (d) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, d),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.description_outlined,
                        color: accentColor,
                        size: 19,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          str(d['title']),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      );
      if (selected != null) {
        await state.bindMeetingNotes(meeting, str(selected['id']));
        if (context.mounted) {
          await OfficeDialogs.document(context, state, selected);
        }
      }
    } catch (e) {
      if (context.mounted) notifyOffice(context, friendlyError(e));
    }
  }

  Future<void> _action(
    BuildContext context,
    Future<void> Function() callback,
  ) async {
    try {
      await callback();
    } catch (e) {
      if (context.mounted) notifyOffice(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final meeting = media.activeMeeting ?? {};
    final people = media.participants;
    final owner = meeting['created_by'] == state.me?['id'];
    return ColoredBox(
      color: const Color(0xff1c1f26),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 15, 12, 15),
              child: Row(
                children: [
                  const Icon(
                    Icons.shield_outlined,
                    size: 17,
                    color: Color(0xff76bd95),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          str(meeting['title']),
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${people.length} 位参与者 · 原生实时会议',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xff9098a8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _notes(context),
                    tooltip: '共同纪要文档',
                    icon: const Icon(
                      Icons.description_outlined,
                      color: Color(0xffb3bbcc),
                      size: 19,
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(
                          text:
                              '${str(meeting['title'])}\n会议 ID：${str(meeting['id'])}',
                        ),
                      );
                      if (context.mounted) notifyOffice(context, '入会信息已复制');
                    },
                    tooltip: '复制入会信息',
                    icon: const Icon(
                      Icons.person_add_alt_outlined,
                      color: Color(0xffb3bbcc),
                      size: 20,
                    ),
                  ),
                  if (owner)
                    PopupMenuButton<String>(
                      tooltip: '主持人操作',
                      icon: const Icon(
                        Icons.more_horiz,
                        color: Color(0xffb3bbcc),
                      ),
                      onSelected: (_) => _action(context, () async {
                        await state.endMeeting(str(meeting['id']));
                        await media.leave();
                      }),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'end',
                          child: Text('结束所有人的会议'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (media.connecting) const LinearProgressIndicator(minHeight: 2),
            if (media.error.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: const Color(0xff553d35),
                child: Text(
                  media.error,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xffffd9c8),
                  ),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = people.length <= 1
                      ? 1
                      : constraints.maxWidth < 600
                      ? 1
                      : people.length <= 4
                      ? 2
                      : 3;
                  return GridView.builder(
                    padding: const EdgeInsets.all(15),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 16 / 10,
                    ),
                    itemCount: people.length,
                    itemBuilder: (context, index) {
                      final p = people[index];
                      final session = str(p['session_id']);
                      final local = session == media.localSessionId;
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const ColoredBox(color: Color(0xff292e38)),
                            if (p['video'] == true || p['sharing'] == true)
                              media.videoFor(session)
                            else
                              Center(
                                child: PersonAvatar(
                                  name: str(p['name']),
                                  agent: p['kind'] == 'agent',
                                  size: 73,
                                ),
                              ),
                            Positioned(
                              left: 12,
                              right: 12,
                              bottom: 10,
                              child: Row(
                                children: [
                                  Icon(
                                    p['audio'] == true
                                        ? Icons.mic_outlined
                                        : Icons.mic_off_outlined,
                                    size: 14,
                                    color: p['audio'] == true
                                        ? const Color(0xff84d3a1)
                                        : const Color(0xffabb4c5),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '${str(p['name'])}${local ? '（你）' : ''}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  if (p['sharing'] == true)
                                    const Text(
                                      '正在共享屏幕',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Color(0xff83caa0),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 18),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xff343a45))),
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: MediaQuery.sizeOf(context).width < 600 ? 17 : 33,
                runSpacing: 15,
                children: [
                  _control(
                    media.microphoneEnabled
                        ? Icons.mic_outlined
                        : Icons.mic_off_outlined,
                    media.microphoneEnabled ? '关闭麦克风' : '打开麦克风',
                    () => _action(
                      context,
                      () => media.setMicrophone(!media.microphoneEnabled),
                    ),
                  ),
                  _control(
                    media.cameraEnabled
                        ? Icons.videocam_outlined
                        : Icons.videocam_off_outlined,
                    media.cameraEnabled ? '关闭摄像头' : '打开摄像头',
                    () => _action(
                      context,
                      () => media.setCamera(!media.cameraEnabled),
                    ),
                  ),
                  _control(
                    media.sharing
                        ? Icons.stop_screen_share_outlined
                        : Icons.screen_share_outlined,
                    media.sharing ? '停止共享' : '共享屏幕',
                    () => _action(
                      context,
                      () => media.setSharing(!media.sharing),
                    ),
                  ),
                  _control(
                    Icons.people_outline,
                    '成员 ${people.length}',
                    () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('会议成员'),
                        content: SizedBox(
                          width: 350,
                          child: ListView(
                            shrinkWrap: true,
                            children: people
                                .map(
                                  (p) => ListTile(
                                    leading: PersonAvatar(
                                      name: str(p['name']),
                                      agent: p['kind'] == 'agent',
                                      size: 30,
                                    ),
                                    title: Text(
                                      str(p['name']),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    subtitle: Text(
                                      p['sharing'] == true
                                          ? '正在共享屏幕'
                                          : p['audio'] == true
                                          ? '麦克风已开启'
                                          : '麦克风已关闭',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: mutedColor,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _control(
                    Icons.call_end,
                    '离开会议',
                    () => _action(context, media.leave),
                    danger: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _control(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          color: danger ? const Color(0xfff58188) : const Color(0xffced5e3),
          size: 25,
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            color: danger ? const Color(0xfff58188) : const Color(0xffa2abbd),
          ),
        ),
      ],
    ),
  );
}
