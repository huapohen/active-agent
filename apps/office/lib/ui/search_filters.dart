import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_theme.dart';

class OfficeSearchFilters {
  const OfficeSearchFilters({this.roomId, this.authorId, this.dates});
  final String? roomId, authorId;
  final DateTimeRange? dates;
  bool get active => roomId != null || authorId != null || dates != null;
  String? get after => dates == null
      ? null
      : DateTime(
          dates!.start.year,
          dates!.start.month,
          dates!.start.day,
        ).toUtc().toIso8601String();
  String? get before => dates == null
      ? null
      : DateTime(
          dates!.end.year,
          dates!.end.month,
          dates!.end.day + 1,
        ).toUtc().toIso8601String();
  OfficeSearchFilters forType(String type) {
    if (['person', 'agent', 'store'].contains(type)) {
      return const OfficeSearchFilters();
    }
    return OfficeSearchFilters(
      roomId: type == 'mail' ? null : roomId,
      authorId: authorId,
      dates: dates,
    );
  }
}

Future<OfficeSearchFilters?> showOfficeSearchFilters(
  BuildContext context,
  OfficeState state, {
  required String type,
  required OfficeSearchFilters initial,
}) => showDialog<OfficeSearchFilters>(
  context: context,
  builder: (_) =>
      _OfficeSearchFilterDialog(state: state, type: type, initial: initial),
);

class _OfficeSearchFilterDialog extends StatefulWidget {
  const _OfficeSearchFilterDialog({
    required this.state,
    required this.type,
    required this.initial,
  });
  final OfficeState state;
  final String type;
  final OfficeSearchFilters initial;
  @override
  State<_OfficeSearchFilterDialog> createState() => _OfficeSearchFilterState();
}

class _OfficeSearchFilterState extends State<_OfficeSearchFilterDialog> {
  late String? _roomId = widget.initial.roomId;
  late String? _authorId = widget.initial.authorId;
  late DateTimeRange? _dates = widget.initial.dates;
  @override
  Widget build(BuildContext context) {
    final people = <String, Json>{
      for (final person in [
        ...widget.state.principals,
        ...widget.state.agents,
        ...widget.state.contacts,
        if (widget.state.me != null) widget.state.me!,
      ])
        if (personId(person).isNotEmpty) personId(person): person,
    };
    final rooms = officeBusinessRooms(widget.state);
    return AlertDialog(
      title: const Text('筛选工作内容'),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey('search-author-${_authorId ?? "all"}'),
                initialValue: people.containsKey(_authorId) ? _authorId : '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '作者 / 发起人'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('所有人与 Agent')),
                  for (final entry in people.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(
                        '${str(entry.value['name'])}${entry.value['kind'] == 'agent' ? ' · Agent' : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _authorId = value == '' ? null : value),
              ),
              const SizedBox(height: 16),
              if (widget.type != 'mail') ...[
                DropdownButtonFormField<String>(
                  key: ValueKey('search-room-${_roomId ?? "all"}'),
                  initialValue: rooms.any((r) => r['id'] == _roomId)
                      ? _roomId
                      : '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '所属会话'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部会话与独立内容')),
                    for (final room in rooms)
                      DropdownMenuItem(
                        value: str(room['id']),
                        child: Text(
                          str(room['name']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _roomId = value == '' ? null : value),
                ),
                const SizedBox(height: 16),
              ],
              OutlinedButton.icon(
                onPressed: () async {
                  final now = DateTime.now();
                  final selected = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(now.year + 1, 12, 31),
                    initialDateRange: _dates,
                    helpText: '选择时间范围（包含起止日）',
                    saveText: '使用此范围',
                  );
                  if (selected != null && mounted) {
                    setState(() => _dates = selected);
                  }
                },
                icon: const Icon(Icons.date_range, size: 18),
                label: Text(
                  _dates == null
                      ? '不限时间 · 选择日期'
                      : '${_date(_dates!.start)} 至 ${_date(_dates!.end)}',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '文档按最近更新时间与可确认的内容编辑者筛选；其他工作内容按创建或发送时间。日期按本机时区，包含起止日。',
                style: TextStyle(fontSize: 11, color: mutedColor, height: 1.7),
              ),
              if (widget.type == 'all')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '设置作者或时间后，不包含联系人和 Agent 目录；指定会话后，只搜索该会话关联的内容。',
                    style: TextStyle(
                      fontSize: 11,
                      color: mutedColor,
                      height: 1.7,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _roomId = null;
            _authorId = null;
            _dates = null;
          }),
          child: const Text('重置'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            OfficeSearchFilters(
              roomId: _roomId,
              authorId: _authorId,
              dates: _dates,
            ),
          ),
          child: const Text('应用筛选'),
        ),
      ],
    );
  }

  String _date(DateTime date) => '${date.year}/${date.month}/${date.day}';
}
