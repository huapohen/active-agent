import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

String approvalStatus(dynamic value) =>
    const {
      'pending': '审批中',
      'approved': '已通过',
      'rejected': '已拒绝',
      'cancelled': '已撤回',
      'expired': '已过期',
      'created': '已提交',
    }[value] ??
    str(value);
Color approvalColor(dynamic value) => value == 'approved'
    ? const Color(0xff2f9c70)
    : value == 'rejected'
    ? const Color(0xffd96565)
    : value == 'pending'
    ? accentColor
    : mutedColor;

class OfficeApprovals extends StatefulWidget {
  const OfficeApprovals({super.key, required this.state});
  final OfficeState state;
  @override
  State<OfficeApprovals> createState() => OfficeApprovalsState();
}

class OfficeApprovalsState extends State<OfficeApprovals> {
  int _tab = 0;
  String _query = '';
  OfficeState get s => widget.state;
  Future<void> create([Json? template]) async {
    final roomId = s.selectedRoomId ?? await chooseOfficeRoom(context, s);
    if (roomId == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _ApprovalForm(state: s, template: template, roomId: roomId),
    );
  }

  Future<void> open(String id) async {
    try {
      final request = await s.getApproval(id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _ApprovalDetail(state: s, request: request),
      );
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = personId(s.me ?? {});
    final requests = s.approvalRequests
        .where(
          (r) =>
              (_tab == 1
                  ? r['created_by'] == myId
                  : _tab == 2
                  ? r['status'] != 'pending'
                  : r['approver_id'] == myId && r['status'] == 'pending') &&
              str(r['title']).toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return Column(
      children: [
        BusinessHeader(
          title: '审批',
          subtitle: '申请、决策与依据，共同可见',
          actions: [
            FilledButton.icon(
              onPressed: create,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('发起申请'),
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              const Text(
                '常用申请',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 13),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: s.approvalTemplates
                    .map(
                      (template) => SizedBox(
                        width: MediaQuery.sizeOf(context).width < 500
                            ? 151
                            : 180,
                        child: Material(
                          color: const Color(0xfff7f9fc),
                          borderRadius: BorderRadius.circular(9),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(9),
                            onTap: () => create(template),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    template['id'] == 'leave'
                                        ? Icons.beach_access_outlined
                                        : template['id'] == 'expense'
                                        ? Icons.receipt_long_outlined
                                        : Icons.fact_check_outlined,
                                    color: accentColor,
                                    size: 25,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    str(template['name']),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
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
              ),
              const SizedBox(height: 25),
              Wrap(
                spacing: 10,
                children: List.generate(
                  3,
                  (i) => ChoiceChip(
                    label: Text(['待我审批', '我发起的', '已完成'][i]),
                    selected: _tab == i,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _tab = i),
                  ),
                ),
              ),
              const SizedBox(height: 15),
              OfficeSearch(
                hint: '搜索申请主题',
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 13),
              if (requests.isEmpty)
                const BusinessCard(
                  child: Text('这里还没有申请。', style: TextStyle(color: mutedColor)),
                )
              else
                ...requests.map(
                  (request) => Material(
                    color: Colors.white,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      leading: const Icon(
                        Icons.article_outlined,
                        color: accentColor,
                      ),
                      title: Text(
                        str(request['title']),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        '${fullOfficeTime(request['created_at'], context: context)} · ${str(s.principals.where((p) => personId(p) == request['created_by']).firstOrNull?['name'], '申请人')}',
                        style: const TextStyle(fontSize: 11, color: mutedColor),
                      ),
                      trailing: Text(
                        approvalStatus(request['status']),
                        style: TextStyle(
                          fontSize: 11,
                          color: approvalColor(request['status']),
                        ),
                      ),
                      onTap: () => open(str(request['id'])),
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

class _ApprovalForm extends StatefulWidget {
  const _ApprovalForm({
    required this.state,
    this.template,
    required this.roomId,
  });
  final OfficeState state;
  final Json? template;
  final String roomId;
  @override
  State<_ApprovalForm> createState() => _ApprovalFormState();
}

class _ApprovalFormState extends State<_ApprovalForm> {
  final _title = TextEditingController(),
      _description = TextEditingController(),
      _amount = TextEditingController(),
      _start = TextEditingController(),
      _end = TextEditingController();
  late String _template = str(widget.template?['id'], 'general');
  String? _approver, _error;
  bool _busy = false;
  DateTime _correctionDay = DateTime.now().toUtc().add(
    const Duration(hours: 8),
  );
  TimeOfDay? _checkIn, _checkOut;
  OfficeState get s => widget.state;
  @override
  void dispose() {
    for (final c in [_title, _description, _amount, _start, _end]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if ((_template != 'attendance_correction' && _title.text.trim().isEmpty) ||
        _approver == null) {
      setState(() => _error = '请填写主题并选择审批人');
      return;
    }
    if (_template == 'expense' &&
        (double.tryParse(_amount.text) == null ||
            double.parse(_amount.text) <= 0)) {
      setState(() => _error = '请填写有效的报销金额');
      return;
    }
    if (_template == 'leave' &&
        (_start.text.trim().isEmpty || _end.text.trim().isEmpty)) {
      setState(() => _error = '请填写请假开始和结束时间');
      return;
    }
    if (_template == 'attendance_correction' &&
        (_checkIn == null || _description.text.trim().isEmpty)) {
      setState(() => _error = '请选择补卡上班时间并填写原因');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_template == 'attendance_correction') {
        String iso(TimeOfDay time) => DateTime.utc(
          _correctionDay.year,
          _correctionDay.month,
          _correctionDay.day,
          time.hour - 8,
          time.minute,
        ).toIso8601String();
        await s.createAttendanceCorrection(
          roomId: widget.roomId,
          date:
              '${_correctionDay.year}-${_correctionDay.month.toString().padLeft(2, '0')}-${_correctionDay.day.toString().padLeft(2, '0')}',
          checkInAt: iso(_checkIn!),
          checkOutAt: _checkOut == null ? null : iso(_checkOut!),
          reason: _description.text.trim(),
          approverId: _approver!,
        );
      } else {
        await s.createApproval(
          roomId: widget.roomId,
          templateId: _template,
          title: _title.text.trim(),
          description: _description.text.trim(),
          approverId: _approver!,
          fields: {
            if (_template == 'expense') ...{
              'amount': double.parse(_amount.text),
              'currency': 'CNY',
            },
            if (_template == 'leave') ...{
              'starts_at': _start.text.trim(),
              'ends_at': _end.text.trim(),
            },
          },
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('发起申请'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _template,
              decoration: const InputDecoration(labelText: '申请类型'),
              items: s.approvalTemplates
                  .map(
                    (t) => DropdownMenuItem(
                      value: str(t['id']),
                      child: Text(str(t['name'])),
                    ),
                  )
                  .toList(),
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _template = value ?? 'general'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              maxLength: 200,
              decoration: const InputDecoration(labelText: '申请主题'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLines: 4,
              maxLength: 8000,
              decoration: const InputDecoration(
                labelText: '申请说明',
                hintText: '背景、原因与需要审批人确认的事项',
              ),
            ),
            if (_template == 'expense') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '报销金额（元）'),
              ),
            ],
            if (_template == 'leave') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _start,
                decoration: const InputDecoration(
                  labelText: '请假开始',
                  hintText: '例如：2026-09-07 09:00',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _end,
                decoration: const InputDecoration(
                  labelText: '请假结束',
                  hintText: '例如：2026-09-07 18:00',
                ),
              ),
            ],
            if (_template == 'attendance_correction') ...[
              const SizedBox(height: 12),
              const Text(
                '补卡时间（Asia/Shanghai）',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final day = await showDatePicker(
                          context: context,
                          initialDate: _correctionDay,
                          firstDate: DateTime(2020),
                          lastDate: DateTime.now().toUtc().add(
                            const Duration(hours: 8),
                          ),
                        );
                        if (day != null && mounted) {
                          setState(() => _correctionDay = day);
                        }
                      },
                icon: const Icon(Icons.calendar_today_outlined, size: 16),
                label: Text(
                  '${_correctionDay.year}/${_correctionDay.month}/${_correctionDay.day}',
                ),
              ),
              Wrap(
                spacing: 10,
                children: [
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime:
                                  _checkIn ??
                                  const TimeOfDay(hour: 9, minute: 0),
                            );
                            if (time != null && mounted) {
                              setState(() => _checkIn = time);
                            }
                          },
                    child: Text(
                      _checkIn == null
                          ? '选择上班时间'
                          : '上班 ${_checkIn!.format(context)}',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime:
                                  _checkOut ??
                                  const TimeOfDay(hour: 18, minute: 0),
                            );
                            if (time != null && mounted) {
                              setState(() => _checkOut = time);
                            }
                          },
                    child: Text(
                      _checkOut == null
                          ? '下班时间（选填）'
                          : '下班 ${_checkOut!.format(context)}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '由指定审批人通过后，更正到你的考勤记录。',
                style: TextStyle(fontSize: 11, color: mutedColor),
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final ids = await chooseOfficePeople(
                        context,
                        s,
                        single: true,
                        title: '选择审批人',
                        selected: _approver == null ? [] : [_approver!],
                        people: officeRoomPeople(s, widget.roomId)
                            .where((p) => personId(p) != personId(s.me ?? {}))
                            .toList(),
                      );
                      if (ids != null && mounted) {
                        setState(() => _approver = ids.firstOrNull);
                      }
                    },
              icon: const Icon(Icons.person_outline, size: 17),
              label: Text(
                _approver == null
                    ? '选择审批人（人或 Agent）'
                    : str(
                        s.principals
                            .where((p) => personId(p) == _approver)
                            .firstOrNull?['name'],
                        '已选择审批人',
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '会话：${str((s.detail?['room'] as Map?)?['name'])}',
              style: const TextStyle(fontSize: 11, color: mutedColor),
            ),
            BusinessError(_error),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(_busy ? '提交中…' : '提交申请'),
      ),
    ],
  );
}

class _ApprovalDetail extends StatefulWidget {
  const _ApprovalDetail({required this.state, required this.request});
  final OfficeState state;
  final Json request;
  @override
  State<_ApprovalDetail> createState() => _ApprovalDetailState();
}

class _ApprovalDetailState extends State<_ApprovalDetail> {
  late Json _request = widget.request;
  final _comment = TextEditingController();
  bool _busy = false;
  String? _error;
  OfficeState get s => widget.state;
  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  String _name(dynamic id) => str(
    s.principals.where((p) => personId(p) == id).firstOrNull?['name'],
    str(id),
  );
  Future<void> _decide(String decision) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (decision == 'cancelled') {
        await s.withdrawApproval(_request);
      } else {
        await s.decideApproval(
          _request,
          decision,
          comment: _comment.text.trim(),
        );
      }
      final next = await s.getApproval(str(_request['id']));
      if (mounted) setState(() => _request = next);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _request,
        pending = _request['status'] == 'pending',
        myId = personId(s.me ?? {});
    return AlertDialog(
      title: Text(str(request['title'])),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                approvalStatus(request['status']),
                style: TextStyle(
                  color: approvalColor(request['status']),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 17),
              Text(
                '申请人：${_name(request['created_by'])}\n审批人：${_name(request['approver_id'])}\n提交时间：${fullOfficeTime(request['created_at'], context: context)}\n有效期至：${fullOfficeTime(request['expires_at'], context: context)}',
                style: const TextStyle(fontSize: 12, height: 1.9),
              ),
              const Divider(height: 30),
              SelectableText(
                str(request['description']),
                style: const TextStyle(fontSize: 13, height: 1.8),
              ),
              if (request['payload'] is Map)
                ..._payloadFields(Json.from(request['payload'])),
              const Divider(height: 30),
              const Text('审批记录', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              ...maps(request['audit']).map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 15),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.radio_button_checked,
                        size: 13,
                        color: accentColor,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_name(entry['actor_id'])} · ${approvalStatus(entry['action'])}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            Text(
                              fullOfficeTime(entry['at'], context: context),
                              style: const TextStyle(
                                fontSize: 10,
                                color: mutedColor,
                              ),
                            ),
                            if (str(entry['comment']).isNotEmpty)
                              Text(
                                str(entry['comment']),
                                style: const TextStyle(fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (pending && request['approver_id'] == myId)
                TextField(
                  controller: _comment,
                  maxLines: 3,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '审批意见'),
                ),
              BusinessError(_error),
              if (_error != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          try {
                            final next = await s.getApproval(
                              str(request['id']),
                            );
                            if (mounted) {
                              setState(() {
                                _request = next;
                                _error = null;
                              });
                            }
                          } catch (e) {
                            if (mounted) {
                              setState(() => _error = friendlyError(e));
                            }
                          }
                        },
                  child: const Text('读取最新审批状态'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (pending && request['created_by'] == myId)
          TextButton(
            onPressed: _busy ? null : () => _decide('cancelled'),
            child: const Text('撤回申请'),
          ),
        if (pending && request['approver_id'] == myId) ...[
          OutlinedButton(
            onPressed: _busy ? null : () => _decide('rejected'),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _decide('approved'),
            child: const Text('同意'),
          ),
        ],
      ],
    );
  }

  List<Widget> _payloadFields(Json payload) {
    const labels = {
      'amount': '金额',
      'currency': '币种',
      'starts_at': '开始时间',
      'ends_at': '结束时间',
      'reason': '原因',
      'date': '日期',
      'check_in_at': '上班时间',
      'check_out_at': '下班时间',
      'principal_id': '补卡成员',
      'timezone': '时区',
      'base_record_revision': '原记录版本',
    };
    String value(String key, dynamic raw) {
      if (key == 'principal_id') return _name(raw);
      if (key == 'timezone' && raw == 'Asia/Shanghai') {
        return '北京时间（UTC+8）';
      }
      if (key == 'base_record_revision') return '第 $raw 版';
      if ({
        'starts_at',
        'ends_at',
        'check_in_at',
        'check_out_at',
      }.contains(key)) {
        final parsed = DateTime.tryParse(str(raw));
        if (parsed != null && payload['timezone'] == 'Asia/Shanghai') {
          final date = parsed.toUtc().add(const Duration(hours: 8));
          String two(int n) => n.toString().padLeft(2, '0');
          return '${date.year}/${two(date.month)}/${two(date.day)} ${officeHourMinute(date, context: context)}（北京时间）';
        }
        return fullOfficeTime(raw, context: context);
      }
      return str(raw);
    }

    final visible = payload.entries.where(
      (e) => e.value != null && str(e.value).isNotEmpty,
    );
    final internal = visible.where((e) => !labels.containsKey(e.key)).toList();
    return [
      ...visible
          .where((e) => labels.containsKey(e.key))
          .map(
            (e) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${labels[e.key]}：${value(e.key, e.value)}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
      if (internal.isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('记录详情', style: TextStyle(fontSize: 12)),
          children: internal
              .map(
                (e) => Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SelectableText(
                      '${const {'record_id': '考勤记录编号'}[e.key] ?? e.key}：${e.value}',
                      style: const TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
    ];
  }
}
