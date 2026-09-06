import 'dart:convert';

import 'package:flutter/material.dart';

import 'business_widgets.dart';
import 'office_theme.dart';

const agentActionNames = {
  'im_create_task': '创建任务',
  'im_update_task': '更新任务',
  'im_add_contact': '添加联系人',
  'office_create_event': '创建日程',
  'office_update_event': '更新日程',
  'office_respond_event': '回复日程邀请',
  'im_create_document': '创建共同文档',
  'im_update_document': '更新共同文档',
};

/// Execution success is derived exclusively from server receipts. A model's
/// prose, planned action, or completed turn is never proof of a committed write.
class AgentActionPlan extends StatelessWidget {
  const AgentActionPlan({super.key, required this.run});
  final Json run;

  @override
  Widget build(BuildContext context) {
    final plan = run['action_plan'] is Map
        ? Json.from(run['action_plan'])
        : <String, dynamic>{};
    final steps = maps(plan['steps']);
    final receipts = maps(run['action_receipts']);
    if (steps.isEmpty && receipts.isEmpty) return const SizedBox.shrink();
    final ended = [
      'cancelled',
      'stale',
      'failed',
      'completed',
    ].contains(run['status']);
    final linked = <String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '行动计划与执行回执',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (str(plan['summary']).isNotEmpty)
          Text(
            str(plan['summary']),
            style: const TextStyle(fontSize: 12, height: 1.8),
          ),
        const SizedBox(height: 8),
        Text(
          '${receipts.where((r) => r['status'] == 'committed').length} 项已提交 · ${receipts.where((r) => r['status'] == 'rejected').length} 项被拒绝',
          style: const TextStyle(fontSize: 11, color: mutedColor),
        ),
        const SizedBox(height: 12),
        ...steps.map((step) {
          final id = str(step['operation_id']);
          final receipt = id.isEmpty
              ? null
              : receipts.where((r) => r['operation_id'] == id).firstOrNull;
          if (receipt != null) linked.add(id);
          return _step(context, step, receipt, ended);
        }),
        ...receipts
            .where((r) => !linked.contains(str(r['operation_id'])))
            .map(
              (r) => _step(
                context,
                {
                  'operation': r['operation'],
                  'operation_id': r['operation_id'],
                },
                r,
                ended,
              ),
            ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _step(BuildContext context, Json step, Json? receipt, bool ended) {
    final status = receipt?['status'];
    final committed = status == 'committed',
        rejected = status == 'rejected',
        applying = status == 'applying';
    final label = committed
        ? '已提交'
        : rejected
        ? '已拒绝'
        : applying
        ? '提交待确认'
        : ended
        ? '未执行'
        : '待执行';
    final color = committed
        ? const Color(0xff289767)
        : rejected
        ? const Color(0xffbc5555)
        : mutedColor;
    final args = step['arguments'] is Map
        ? Json.from(step['arguments'])
        : <String, dynamic>{};
    final human = <String, String>{
      'title': '标题',
      'description': '说明',
      'status': '任务状态',
      'starts_at': '开始时间',
      'ends_at': '结束时间',
      'location': '地点',
      'response': '回复',
    };
    String value(String key, dynamic raw) {
      if (key == 'starts_at' || key == 'ends_at') {
        return fullOfficeTime(raw, context: context);
      }
      if (key == 'status') return statusName(raw);
      if (key == 'response') {
        return const {
              'accepted': '接受',
              'declined': '拒绝',
              'tentative': '待定',
            }[raw] ??
            str(raw);
      }
      return str(raw);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: BusinessCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  committed
                      ? Icons.check_circle_outline
                      : rejected
                      ? Icons.error_outline
                      : Icons.pending_outlined,
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    agentActionNames[step['operation']] ??
                        str(step['operation'], '工作动作'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(label, style: TextStyle(fontSize: 11, color: color)),
              ],
            ),
            ...args.entries
                .where(
                  (e) =>
                      human.containsKey(e.key) &&
                      e.value != null &&
                      str(e.value).isNotEmpty,
                )
                .map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(
                      '${human[entry.key]}：${value(entry.key, entry.value)}',
                      style: const TextStyle(fontSize: 12, height: 1.8),
                    ),
                  ),
                ),
            if (receipt?['committed_at'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '服务端记录：${fullOfficeTime(receipt!['committed_at'], context: context)}',
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              ),
            if (receipt?['after_revision'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  '共同版本：r${receipt!['after_revision']}',
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              ),
            if (rejected)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '此动作没有提交成功，拒绝原因保留在回执详情。',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ),
            if (applying)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '正在等待服务端恢复持久文档回执，当前结果尚未确认。',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ),
            if (receipt == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  ended ? '本轮已结束，该步骤没有服务端执行回执。' : '已列入计划，正在等待服务端执行回执。',
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                '计划依据与回执详情',
                style: TextStyle(fontSize: 11, color: accentColor),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ')
                        .convert({'step': step, 'receipt': ?receipt}),
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.8,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
