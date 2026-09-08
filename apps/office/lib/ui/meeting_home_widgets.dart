import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'office_theme.dart';

class OfficeMeetingHome extends StatelessWidget {
  const OfficeMeetingHome({
    super.key,
    required this.meetings,
    required this.onCreate,
    required this.onJoin,
    required this.onSchedule,
    required this.onCalendar,
    required this.onMinutes,
    required this.onUnavailable,
    required this.onOpen,
    required this.query,
    this.busy = false,
    this.error = '',
    this.mobileHeaderLeading,
  });
  final List<Json> meetings;
  final VoidCallback onCreate, onJoin, onSchedule, onCalendar, onMinutes;
  final ValueChanged<String> onUnavailable;
  final ValueChanged<Json> onOpen;
  final String query, error;
  final bool busy;
  final Widget? mobileHeaderLeading;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 700;
      final entries = _entries(context, desktop: desktop);
      final content = _records(context, desktop: desktop);
      return desktop
          ? Row(
              children: [
                SizedBox(
                  key: const ValueKey('meeting-launcher-pane'),
                  width: 350,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    children: entries,
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: const Color(0xfff7f8fa),
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: content,
                    ),
                  ),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              children: [...entries, const SizedBox(height: 24), ...content],
            );
    },
  );

  List<Widget> _entries(BuildContext context, {required bool desktop}) {
    final allEntries = [
      ('发起会议', Icons.videocam_rounded, 0xffe3e9ff, 0xff3d73ed, onCreate),
      ('加入会议', Icons.add_box_rounded, 0xffe3e9ff, 0xff3d73ed, onJoin),
      (
        '预约会议',
        Icons.calendar_month_rounded,
        0xffffe8ce,
        0xfff48a30,
        onSchedule,
      ),
      (
        '网络研讨会',
        Icons.co_present_rounded,
        0xffffe8ce,
        0xfff48a30,
        () => onUnavailable('网络研讨会'),
      ),
      (
        '会议室投屏',
        Icons.present_to_all_rounded,
        0xffd3f4cc,
        0xff59c25a,
        () => onUnavailable('会议室投屏'),
      ),
      ('人机妙记', Icons.graphic_eq_rounded, 0xffebe9fb, 0xff7566df, onMinutes),
      (
        '智能纪要',
        Icons.notes_rounded,
        0xffe3e9ff,
        0xff3d73ed,
        () => onUnavailable('智能纪要'),
      ),
      (
        '直播',
        Icons.live_tv_rounded,
        0xffe3e9ff,
        0xff3d73ed,
        () => onUnavailable('直播'),
      ),
      (
        '电话',
        Icons.phone_rounded,
        0xffe3e9ff,
        0xff3d73ed,
        () => onUnavailable('电话'),
      ),
    ];
    final entries = desktop
        ? allEntries
        : [
            allEntries[0],
            allEntries[1],
            allEntries[2],
            allEntries[5],
            (
              'AI 录音',
              Icons.mic_rounded,
              0xffebe9fb,
              0xff7566df,
              () => onUnavailable('AI 录音'),
            ),
            allEntries[6],
            allEntries[8],
          ];
    return [
      Row(
        children: [
          if (!desktop && mobileHeaderLeading != null) ...[
            mobileHeaderLeading!,
            const SizedBox(width: 8),
          ],
          const Expanded(
            child: Text(
              '视频会议',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: '搜索会议',
            onPressed: () => onUnavailable('搜索会议'),
            icon: const Icon(Icons.search, size: 22),
          ),
          IconButton(
            tooltip: '会议设置',
            onPressed: () => onUnavailable('会议设置'),
            icon: const Icon(Icons.settings_outlined, size: 21),
          ),
        ],
      ),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final columns = desktop ? 2 : 4;
          final gap = desktop ? 16.0 : 8.0;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          final labelStyle = DefaultTextStyle.of(context).style.merge(
            TextStyle(fontSize: desktop ? 14 : 12, fontWeight: FontWeight.w500),
          );
          var labelHeight = 0.0;
          for (final entry in entries) {
            final painter = TextPainter(
              text: TextSpan(text: entry.$1, style: labelStyle),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: width - (desktop ? 32 : 0));
            labelHeight = math.max(labelHeight, painter.height);
            painter.dispose();
          }
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: entries
                .map(
                  (entry) => SizedBox(
                    width: width,
                    height: desktop
                        ? math.max(114, 88 + labelHeight)
                        : math.max(84, 56 + labelHeight),
                    child: Material(
                      color: desktop ? Color(entry.$3) : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        key: ValueKey('meeting-entry-${entry.$1}'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: busy ? null : entry.$5,
                        child: Padding(
                          padding: EdgeInsets.all(desktop ? 16 : 0),
                          child: Column(
                            crossAxisAlignment: desktop
                                ? CrossAxisAlignment.start
                                : CrossAxisAlignment.center,
                            children: [
                              Container(
                                width: desktop ? 44 : 48,
                                height: desktop ? 44 : 48,
                                decoration: BoxDecoration(
                                  color: desktop
                                      ? Colors.white
                                      : Color(entry.$3),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(
                                  entry.$2,
                                  size: 25,
                                  color: Color(entry.$4),
                                ),
                              ),
                              if (desktop)
                                const Spacer()
                              else
                                const SizedBox(height: 8),
                              Text(
                                entry.$1,
                                style: TextStyle(
                                  fontSize: desktop ? 14 : 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          );
        },
      ),
    ];
  }

  List<Widget> _records(BuildContext context, {required bool desktop}) {
    final filtered = meetings
        .where(
          (meeting) =>
              str(meeting['title']).toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final upcoming = filtered.where((m) => m['status'] != 'ended').toList()
      ..sort((a, b) => str(a['starts_at']).compareTo(str(b['starts_at'])));
    final history = filtered.where((m) => m['status'] == 'ended').toList()
      ..sort(
        (a, b) =>
            str(b['ended_at'] ?? b['created_at'])
                .compareTo(str(a['ended_at'] ?? a['created_at'])),
      );
    return [
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(error, style: const TextStyle(color: Colors.redAccent)),
        ),
      if (busy) const LinearProgressIndicator(minHeight: 2),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const CircleAvatar(
              backgroundColor: Color(0xffe5ebff),
              child: Icon(
                Icons.notes_rounded,
                color: Color(0xff4f7ce4),
                size: 21,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('共同纪要，留在文档中', style: TextStyle(fontSize: 14)),
                  SizedBox(height: 5),
                  Text(
                    '人和 Agent 共享会议资料',
                    style: TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '打开人机妙记',
              onPressed: onMinutes,
              icon: const Icon(Icons.chevron_right, size: 21),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          const Expanded(
            child: Text(
              '即将开始',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(
            onPressed: onCalendar,
            child: const Text(
              '在日历中查看全部 ›',
              style: TextStyle(fontSize: 12, color: mutedColor),
            ),
          ),
        ],
      ),
      _list(context, upcoming, history: false, desktop: desktop),
      const SizedBox(height: 22),
      const Text(
        '历史记录',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      const SizedBox(height: 12),
      _list(context, history, history: true, desktop: desktop),
    ];
  }

  Widget _list(
    BuildContext context,
    List<Json> entries, {
    required bool history,
    required bool desktop,
  }) => Container(
    key: ValueKey(history ? 'meeting-history-list' : 'meeting-upcoming-list'),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    child: entries.isEmpty
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 30),
            child: Center(
              child: Text(
                query.isNotEmpty
                    ? '没有匹配的会议'
                    : history
                    ? '暂无历史会议'
                    : '暂无即将开始的会议',
                style: const TextStyle(fontSize: 13, color: mutedColor),
              ),
            ),
          )
        : Column(
            children: [
              for (var index = 0; index < entries.length; index++) ...[
                if (index > 0) const Divider(height: 1),
                _row(
                  context,
                  entries[index],
                  history: history,
                  desktop: desktop,
                ),
              ],
            ],
          ),
  );

  Widget _row(
    BuildContext context,
    Json meeting, {
    required bool history,
    required bool desktop,
  }) {
    final start = meeting['starts_at'] ?? meeting['created_at'];
    final meta =
        '${clockText(start, date: true, context: context)} · '
        '${meeting['duration_minutes'] ?? 30} 分钟';
    if (desktop && !history) return _upcomingDesktopRow(context, meeting, meta);
    return InkWell(
      key: ValueKey('meeting-record-${meeting['id']}'),
      onTap: busy ? null : () => onOpen(meeting),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: history ? 20 : 17),
        child: Row(
          children: [
            Container(
              width: history && desktop ? 112 : 36,
              height: history && desktop ? 74 : 36,
              decoration: BoxDecoration(
                color: const Color(0xffe4eafe),
                borderRadius: BorderRadius.circular(history ? 7 : 18),
              ),
              child: Icon(
                Icons.videocam_outlined,
                color: const Color(0xff4f79e6),
                size: history ? 28 : 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    str(meeting['title']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: desktop ? 14 : 16),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    meta,
                    style: TextStyle(
                      fontSize: desktop ? 12 : 13,
                      color: mutedColor,
                    ),
                  ),
                  if (meeting['status'] == 'active')
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '进行中 · 当前在线 ${meeting['participant_count'] ?? 0} 个会话',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff35a16b),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              history ? Icons.chevron_right : Icons.login,
              size: 18,
              color: mutedColor,
            ),
          ],
        ),
      ),
    );
  }

  Widget _upcomingDesktopRow(BuildContext context, Json meeting, String meta) {
    final active = meeting['status'] == 'active';
    final status = active
        ? ' · 进行中 · 当前在线 ${meeting['participant_count'] ?? 0} 个会话'
        : '';
    final complete = '${str(meeting['title'])}\n$meta$status';
    return Tooltip(
      message: complete,
      child: InkWell(
        key: ValueKey('meeting-record-${meeting['id']}'),
        onTap: busy ? null : () => onOpen(meeting),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xffe4eafe),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.videocam_outlined,
                  size: 20,
                  color: Color(0xff4f79e6),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      str(meeting['title']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.3),
                    ),
                    const SizedBox(height: 5),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: meta),
                          if (active)
                            TextSpan(
                              text: status,
                              style: const TextStyle(color: Color(0xff35a16b)),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: mutedColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.login, size: 18, color: mutedColor),
            ],
          ),
        ),
      ),
    );
  }
}

class OfficeMeetingJoinPreview extends StatelessWidget {
  const OfficeMeetingJoinPreview({
    super.key,
    required this.controller,
    required this.name,
    required this.agent,
    required this.onClose,
    required this.onJoin,
  });
  final TextEditingController controller;
  final String name;
  final bool agent;
  final VoidCallback onClose, onJoin;

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    key: const ValueKey('meeting-join-fullscreen'),
    backgroundColor: Colors.white,
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 650;
          return SingleChildScrollView(
            child: SizedBox(
              height: math.max(constraints.maxHeight, desktop ? 480 : 560),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  desktop ? 30 : 16,
                  10,
                  desktop ? 30 : 16,
                  desktop ? 20 : 42,
                ),
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        tooltip: '关闭加入会议',
                        onPressed: onClose,
                        icon: const Icon(Icons.close),
                      ),
                    ),
                    SizedBox(height: desktop ? 10 : 38),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: desktop ? 270 : 210,
                      ),
                      child: TextField(
                        key: const ValueKey('meeting-join-id-input'),
                        controller: controller,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 24),
                        decoration: const InputDecoration(
                          hintText: '会议 ID',
                          hintStyle: TextStyle(
                            fontSize: 24,
                            color: Color(0xff8f959e),
                          ),
                          filled: false,
                          border: UnderlineInputBorder(
                            borderSide: BorderSide(color: Color(0xffdfe1e5)),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Color(0xff7192e3)),
                          ),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Color(0xffdfe1e5)),
                          ),
                        ),
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) {
                          if (controller.text.trim().isNotEmpty) onJoin();
                        },
                      ),
                    ),
                    SizedBox(height: desktop ? 38 : 30),
                    Expanded(
                      child: Container(
                        key: const ValueKey('meeting-join-idle-preview'),
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: const Color(0xfff1f2f3),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Center(
                          child: PersonAvatar(
                            name: name,
                            agent: agent,
                            size: math.min(
                              desktop ? 208 : 188,
                              constraints.maxHeight * .3,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (desktop) ...[
                      const Text(
                        '加入后可开启音视频与屏幕共享',
                        style: TextStyle(fontSize: 12, color: mutedColor),
                      ),
                      const SizedBox(height: 8),
                      _desktopControls(),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(
                            child: _device(Icons.mic_off, '麦克风', '麦克风已关闭'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _device(Icons.videocam_off, '摄像头', '摄像头已关闭'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _device(
                              Icons.volume_up,
                              '扬声器',
                              '音量由系统控制',
                              muted: false,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '加入后可开启音视频与屏幕共享',
                        style: TextStyle(fontSize: 12, color: mutedColor),
                      ),
                      SizedBox(height: desktop ? 12 : 30),
                      Align(
                        alignment: desktop
                            ? Alignment.centerRight
                            : Alignment.center,
                        child: SizedBox(
                          width: desktop ? 150 : double.infinity,
                          height: 46,
                          child: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: controller,
                            builder: (context, value, _) => FilledButton(
                              onPressed: value.text.trim().isEmpty
                                  ? null
                                  : onJoin,
                              child: const Text(
                                '加入会议',
                                style: TextStyle(fontSize: 17),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _desktopControls() => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 12.0, joinWidth = 120.0;
      final deviceWidth = math.min(
        114.0,
        (constraints.maxWidth - joinWidth - gap * 3) / 3,
      );
      final speakerWidth = math.min(
        210.0,
        constraints.maxWidth - joinWidth - deviceWidth * 2 - gap * 3,
      );
      Widget device(
        String key,
        double width,
        IconData icon,
        String label,
        String hint, {
        bool muted = true,
      }) => SizedBox(
        key: ValueKey(key),
        width: width,
        height: 42,
        child: Tooltip(
          message: hint,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xfff4f5f6),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: muted ? const Color(0xffec6262) : mutedColor,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      );
      return Row(
        key: const ValueKey('meeting-desktop-join-controls'),
        children: [
          device(
            'meeting-desktop-microphone',
            deviceWidth,
            Icons.mic_off,
            '麦克风',
            '麦克风已关闭',
          ),
          const SizedBox(width: gap),
          device(
            'meeting-desktop-camera',
            deviceWidth,
            Icons.videocam_off,
            '摄像头',
            '摄像头已关闭',
          ),
          const SizedBox(width: gap),
          device(
            'meeting-desktop-speaker',
            speakerWidth,
            Icons.volume_up,
            '扬声器',
            '音量由系统控制',
            muted: false,
          ),
          const SizedBox(width: gap),
          const Spacer(),
          SizedBox(
            key: const ValueKey('meeting-desktop-join-button'),
            width: joinWidth,
            height: 42,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: value.text.trim().isEmpty ? null : onJoin,
                child: const Text('加入会议', style: TextStyle(fontSize: 17)),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _device(
    IconData icon,
    String label,
    String hint, {
    bool muted = true,
  }) => Tooltip(
    message: hint,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xfff4f5f6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 20,
            color: muted ? const Color(0xffec6262) : mutedColor,
          ),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(fontSize: 12, color: mutedColor)),
        ],
      ),
    ),
  );
}
