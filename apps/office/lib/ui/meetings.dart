import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import '../meeting_controller.dart';
import 'office_dialogs.dart';
import 'meeting_home_widgets.dart';
import 'office_theme.dart';

class OfficeMeetings extends StatefulWidget {
  const OfficeMeetings({
    super.key,
    required this.state,
    required this.media,
    required this.onCalendar,
    this.onMinutes,
    this.mobileHeaderLeading,
  });
  final OfficeState state;
  final MeetingMediaController media;
  final VoidCallback onCalendar;
  final VoidCallback? onMinutes;
  final Widget? mobileHeaderLeading;
  @override
  State<OfficeMeetings> createState() => OfficeMeetingsState();
}

class OfficeMeetingsState extends State<OfficeMeetings> {
  Future<void> createMeeting() => _create();
  Future<void> joinMeeting() => _joinPreview();
  bool _busy = false;
  String _query = '';
  OfficeState get s => widget.state;
  MeetingMediaController get media => widget.media;
  Future<void> _join(String id, [_MeetingScope? originalScope]) async {
    final scope =
        originalScope ??
        _MeetingScope(s, currentState: () => mounted ? s : null);
    if (!mounted || !scope.current) return;
    setState(() => _busy = true);
    try {
      await media.join(s, id.trim());
    } catch (e) {
      if (mounted && scope.current) notifyOffice(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinPreview([String? initial]) async {
    final scope = _MeetingScope(s, currentState: () => mounted ? s : null);
    final controller = TextEditingController(text: initial ?? '');
    final route = DialogRoute<String>(
      context: context,
      useSafeArea: false,
      builder: (dialogContext) => AnimatedBuilder(
        animation: s,
        builder: (context, _) => !scope.current
            ? _expiredMeetingDialog(dialogContext)
            : OfficeMeetingJoinPreview(
                controller: controller,
                name: str(s.me?['name']),
                agent: s.me?['kind'] == 'agent',
                onClose: () => Navigator.pop(dialogContext),
                onJoin: () {
                  if (scope.current && controller.text.trim().isNotEmpty) {
                    Navigator.pop(dialogContext, controller.text.trim());
                  }
                },
              ),
      ),
    );
    final id = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    controller.dispose();
    if (id != null && mounted && scope.current) await _join(id, scope);
  }

  Future<void> _create({bool scheduled = false}) async {
    final scope = _MeetingScope(s, currentState: () => mounted ? s : null);
    final roomId = s.selectedRoomId ?? await chooseOfficeRoom(context, s);
    if (roomId == null || !mounted || !scope.current) return;
    final documents = officeRoomDocuments(s, roomId);
    final title = TextEditingController(
      text: scheduled ? '' : '${str(s.me?['name'])} 的会议',
    );
    var starts = DateTime.now().add(const Duration(hours: 1));
    var duration = 30, busy = false;
    String? documentId;
    String? error;
    late final DialogRoute<Json> route;
    route = DialogRoute<Json>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: s,
        builder: (_, _) => !scope.current
            ? _expiredMeetingDialog(dialogContext)
            : StatefulBuilder(
                builder: (context, change) => AlertDialog(
                  title: Text(
                    scheduled ? '预约会议' : '发起会议',
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
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
                            enabled: !busy,
                            autofocus: true,
                            decoration: const InputDecoration(
                              labelText: '会议主题',
                              hintText: '给这次讨论起个名字',
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '会话：${officeRoomName(s, roomId)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: mutedColor,
                            ),
                          ),
                          if (scheduled) ...[
                            const SizedBox(height: 18),
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      if (!scope.current || busy) return;
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
                                      if (date == null ||
                                          !context.mounted ||
                                          !scope.current) {
                                        return;
                                      }
                                      final time = await showTimePicker(
                                        context: context,
                                        initialTime: TimeOfDay.fromDateTime(
                                          starts,
                                        ),
                                      );
                                      if (time != null &&
                                          context.mounted &&
                                          scope.current) {
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
                              icon: const Icon(
                                Icons.schedule_outlined,
                                size: 18,
                              ),
                              label: Text(
                                clockText(
                                  starts.toIso8601String(),
                                  date: true,
                                  context: context,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            DropdownButtonFormField<int>(
                              initialValue: duration,
                              decoration: const InputDecoration(
                                labelText: '预计时长',
                              ),
                              items: [15, 30, 45, 60, 90, 120]
                                  .map(
                                    (m) => DropdownMenuItem(
                                      value: m,
                                      child: Text('$m 分钟'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: busy
                                  ? null
                                  : (v) => duration = v ?? 30,
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (documents.isNotEmpty) ...[
                            DropdownButtonFormField<String>(
                              initialValue: '',
                              decoration: const InputDecoration(
                                labelText: '关联会议文档',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('暂不关联'),
                                ),
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
                              onChanged: busy
                                  ? null
                                  : (id) => documentId = id?.isEmpty == true
                                        ? null
                                        : id,
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
                      onPressed: busy
                          ? null
                          : () => Navigator.pop(dialogContext),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (!scope.current) return;
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
                                if (dialogContext.mounted &&
                                    scope.current &&
                                    route.isCurrent) {
                                  Navigator.pop(dialogContext, result);
                                }
                              } catch (e) {
                                if (dialogContext.mounted && scope.current) {
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
      ),
    );
    final meeting = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(route);
    await route.completed;
    title.dispose();
    if (meeting != null && mounted && scope.current) {
      if (scheduled) {
        if (mounted) notifyOffice(context, '会议已预约，工作会话成员可查看与加入。');
      } else {
        await _join(str(meeting['id']), scope);
      }
    }
  }

  Future<void> _information(String title, String message) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  Future<void> _homeAction(String action) async {
    final scope = _MeetingScope(s, currentState: () => mounted ? s : null);
    if (action == '搜索会议') {
      final controller = TextEditingController(text: _query);
      final route = DialogRoute<String>(
        context: context,
        builder: (context) => AnimatedBuilder(
          animation: s,
          builder: (context, _) => !scope.current
              ? _expiredMeetingDialog(context)
              : AlertDialog(
                  title: const Text('搜索会议'),
                  content: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: '按会议主题搜索'),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () {
                        if (scope.current) {
                          Navigator.pop(context, controller.text);
                        }
                      },
                      child: const Text('搜索'),
                    ),
                  ],
                ),
        ),
      );
      final query = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      await route.completed;
      controller.dispose();
      if (query != null && mounted && scope.current) {
        setState(() => _query = query);
      }
      return;
    }
    final message = switch (action) {
      '会议设置' =>
        '加入会议时麦克风和摄像头默认关闭。入会后可以分别开启音视频和屏幕共享。当前最多支持六个并发媒体会话；跨网络媒体连接需要配置中继服务。',
      '会议室投屏' => '会议室设备投屏协议尚未接入。你可以加入人机会议后使用屏幕共享。',
      '网络研讨会' => '网络研讨会的报名、观众席和主持人控制尚未接入。当前支持人和 Agent 同权的会话视频会议。',
      'AI 录音' => '会议录音和自动转写入口尚未接入。已有音频资料可在人机妙记中关联；这不会自动开始录音。',
      '智能纪要' => '自动转写和总结服务尚未配置。人机妙记支持共享逐字稿、现有录音资料、纪要文档和任务。',
      '直播' => '直播推流和观众服务尚未接入。',
      '电话' => '运营商电话和电话会议服务尚未接入。',
      _ => '人机妙记入口尚未接入当前页面。',
    };
    await _information(action, message);
  }

  Future<void> _record(Json initial) async {
    if (initial['status'] != 'ended') return _joinPreview(str(initial['id']));
    final scope = _MeetingScope(s, currentState: () => mounted ? s : null);
    try {
      final details = await s.meetingDetail(str(initial['id']));
      if (!mounted || !scope.current) return;
      final meeting = Map<String, dynamic>.from(details['meeting']);
      await showDialog<void>(
        context: context,
        builder: (context) => AnimatedBuilder(
          animation: s,
          builder: (context, _) => !scope.current
              ? _expiredMeetingDialog(context)
              : AlertDialog(
                  title: Text(str(meeting['title'])),
                  content: SizedBox(
                    width: 420,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText('会议 ID：${str(meeting['id'])}'),
                          const SizedBox(height: 14),
                          Text(
                            '会话：${officeRoomName(s, str(meeting['room_id']))}',
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '开始时间：${fullOfficeTime(meeting['starts_at'], context: context)}',
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '结束时间：${fullOfficeTime(meeting['ended_at'], context: context)}',
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            '这里保留会议信息与关联资料。音视频未录制，历史参会名单未保存。',
                            style: TextStyle(fontSize: 13, color: mutedColor),
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                    if (meeting['calendar_event_id'] != null)
                      TextButton(
                        onPressed: () {
                          if (!scope.current) return;
                          Navigator.pop(context);
                          widget.onCalendar();
                        },
                        child: const Text('查看日历'),
                      ),
                    if ((meeting['notes_document_current'] ??
                            meeting['notes_document'])
                        is Map)
                      TextButton(
                        onPressed: () {
                          if (!scope.current) return;
                          Navigator.pop(context);
                          final reference =
                              meeting['notes_document_current'] ??
                              meeting['notes_document'];
                          OfficeDialogs.document(this.context, s, {
                            'id': reference['id'],
                            'room_id': meeting['room_id'],
                          });
                        },
                        child: const Text('共同纪要'),
                      ),
                  ],
                ),
        ),
      );
    } catch (e) {
      if (mounted && scope.current) notifyOffice(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([media, s]),
    builder: (context, _) {
      if (media.activeMeeting != null) {
        return MeetingRoom(state: s, media: media);
      }
      return OfficeMeetingHome(
        meetings: s.meetings,
        query: _query,
        busy: _busy,
        error: media.error,
        mobileHeaderLeading: widget.mobileHeaderLeading,
        onCreate: () => _create(),
        onJoin: () => _joinPreview(),
        onSchedule: () => _create(scheduled: true),
        onCalendar: widget.onCalendar,
        onMinutes: widget.onMinutes ?? () => _homeAction('人机妙记'),
        onUnavailable: _homeAction,
        onOpen: _record,
      );
    },
  );
}

class _MeetingScope {
  _MeetingScope(this.state, {this.currentState})
    : generation = state.identityGeneration,
      endpoint = state.endpoint,
      principalId = state.me?['id'];
  final OfficeState state;
  final OfficeState? Function()? currentState;
  final int generation;
  final String endpoint;
  final dynamic principalId;
  bool get current =>
      (currentState == null || identical(currentState!(), state)) &&
      principalId != null &&
      state.identityGeneration == generation &&
      state.endpoint == endpoint &&
      state.me?['id'] == principalId &&
      state.moduleAvailable('meetings');
}

Widget _expiredMeetingDialog(BuildContext context) => AlertDialog(
  title: const Text('工作身份已变化'),
  content: const Text('请关闭此页面，使用当前身份重新打开。'),
  actions: [
    TextButton(
      onPressed: () => Navigator.pop(context),
      child: const Text('关闭'),
    ),
  ],
);

bool _canManageMeeting(OfficeState state, Json meeting) {
  final id = str(state.me?['id']);
  if (id.isEmpty) return false;
  if (meeting['created_by'] == id) return true;
  // The library intentionally omits roles, so use the authenticated room view.
  final room = state.rooms
      .where((r) => r['id'] == meeting['room_id'])
      .firstOrNull;
  if (room?['created_by'] == id) return true;
  if (state.detail?['room']?['id'] == meeting['room_id']) {
    return maps(state.detail?['members'])
        .any((p) => personId(p) == id && p['role'] == 'owner');
  }
  return false;
}

class MeetingRoom extends StatelessWidget {
  const MeetingRoom({super.key, required this.state, required this.media});
  final OfficeState state;
  final MeetingMediaController media;
  Future<void> _notes(
    BuildContext context,
    _MeetingScope scope,
    String meetingId,
  ) async {
    bool current() => scope.current && media.activeMeeting?['id'] == meetingId;
    if (!current()) return;
    try {
      final details = await state.meetingDetail(meetingId);
      if (!context.mounted || !current()) return;
      final meeting = Map<String, dynamic>.from(details['meeting']);
      final roomId = str(meeting['room_id']);
      var documents = officeRoomDocuments(state, roomId);
      final reference =
          meeting['notes_document_current'] ?? meeting['notes_document'];
      if (reference is Map) {
        await OfficeDialogs.document(context, state, {
          'id': reference['id'],
          'room_id': roomId,
        });
        return;
      }
      if (!_canManageMeeting(state, meeting)) {
        notifyOffice(context, '会议尚未关联纪要，请由会议创建者或会话所有者关联文档。');
        return;
      }
      if (documents.isEmpty) {
        await OfficeDialogs.document(context, state, {'room_id': roomId});
        if (!context.mounted || !current()) return;
        documents = officeRoomDocuments(state, roomId);
        if (documents.isEmpty) return;
      }
      final selected = await showDialog<Json>(
        context: context,
        builder: (dialogContext) => AnimatedBuilder(
          animation: Listenable.merge([state, media]),
          builder: (_, _) => !current()
              ? _expiredMeetingDialog(dialogContext)
              : SimpleDialog(
                  title: const Text('关联共同纪要文档', style: TextStyle(fontSize: 18)),
                  children: documents
                      .map(
                        (d) => SimpleDialogOption(
                          onPressed: () {
                            if (current()) Navigator.pop(dialogContext, d);
                          },
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
        ),
      );
      if (selected != null && context.mounted && current()) {
        await state.bindMeetingNotes(meeting, str(selected['id']));
        if (context.mounted && current()) {
          await OfficeDialogs.document(context, state, {
            ...selected,
            'room_id': roomId,
          });
        }
      }
    } catch (e) {
      if (context.mounted && current()) notifyOffice(context, friendlyError(e));
    }
  }

  Future<void> _action(
    BuildContext context,
    Future<void> Function() callback,
    _MeetingScope scope,
    String meetingId,
  ) async {
    if (!scope.current || media.activeMeeting?['id'] != meetingId) return;
    try {
      await callback();
    } catch (e) {
      if (context.mounted && scope.current) {
        notifyOffice(context, friendlyError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final meeting = media.activeMeeting ?? {};
    final people = media.participants;
    final owner = _canManageMeeting(state, meeting);
    final scope = _MeetingScope(
      state,
      currentState: () => context.mounted && context.widget is MeetingRoom
          ? (context.widget as MeetingRoom).state
          : null,
    );
    final meetingId = str(meeting['id']);
    bool current() => scope.current && media.activeMeeting?['id'] == meetingId;
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
                    onPressed: () => _notes(context, scope, meetingId),
                    tooltip: '共同纪要文档',
                    icon: const Icon(
                      Icons.description_outlined,
                      color: Color(0xffb3bbcc),
                      size: 19,
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      if (!current()) return;
                      await Clipboard.setData(
                        ClipboardData(
                          text:
                              '${str(meeting['title'])}\n会议 ID：${str(meeting['id'])}',
                        ),
                      );
                      if (context.mounted && current()) {
                        notifyOffice(context, '入会信息已复制');
                      }
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
                      onSelected: (_) => _action(
                        context,
                        () async {
                          await state.endMeeting(meetingId);
                          if (current()) await media.leave();
                        },
                        scope,
                        meetingId,
                      ),
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
                      scope,
                      meetingId,
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
                      scope,
                      meetingId,
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
                      scope,
                      meetingId,
                    ),
                  ),
                  _control(
                    Icons.people_outline,
                    '成员 ${people.length}',
                    () => showDialog<void>(
                      context: context,
                      builder: (context) => AnimatedBuilder(
                        animation: Listenable.merge([state, media]),
                        builder: (context, _) => !current()
                            ? _expiredMeetingDialog(context)
                            : AlertDialog(
                                title: const Text('当前在线成员'),
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
                                              style: const TextStyle(
                                                fontSize: 13,
                                              ),
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
                  ),
                  _control(
                    Icons.call_end,
                    '离开会议',
                    () => _action(context, media.leave, scope, meetingId),
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
