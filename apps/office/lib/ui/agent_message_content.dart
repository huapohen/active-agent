import 'package:flutter/material.dart';

import 'office_theme.dart';
import 'office_emoji.dart';

/// Only a server-bound, unchanged turn result can have its appendix folded.
/// The visible success count comes from matching durable receipts, never prose.
class AgentMessageContent extends StatefulWidget {
  const AgentMessageContent({
    super.key,
    required this.message,
    required this.runs,
    required this.onRecords,
    this.onAction,
    this.onOpenMessageMenu,
    this.selectable = true,
  });
  final Json message;
  final ValueChanged<String>? onAction;
  final ValueChanged<Offset>? onOpenMessageMenu;
  final bool selectable;
  final List<Json> runs;
  final void Function(String turnId) onRecords;
  @override
  State<AgentMessageContent> createState() => _AgentMessageContentState();
}

class _AgentMessageContentState extends State<AgentMessageContent> {
  bool _expanded = false;
  TextStyle get _bodyStyle => TextStyle(
    fontSize: officeFontSize(
      context,
      desktop: 13,
      mobile: OfficeMobileType.body,
    ),
    height: MediaQuery.sizeOf(context).width < 760 ? 1.5 : 1.7,
  );

  Widget _selectable(String content) => OfficeEmojiText(
    content: content,
    style: _bodyStyle,
    onAction: widget.onAction,
    onOpenMessageMenu: widget.onOpenMessageMenu,
    selectable: widget.selectable,
  );
  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final content = str(message['content']);
    final turnId = str(message['turn_id']);
    final authorId = str(message['author_id']);
    final run = widget.runs
        .where(
          (run) =>
              turnId.isNotEmpty &&
              run['id'] == turnId &&
              authorId.isNotEmpty &&
              run['principal_id'] == authorId,
        )
        .firstOrNull;
    final result = run?['result'] is Map
        ? Json.from(run!['result'])
        : <String, dynamic>{};
    final summaries = maps(result['action_summary']);
    final appendix =
        '\n\n[服务端动作回执]\n${summaries.map((item) => '${item['operation']}: ${item['status']}'
            '${str(item['resource_id']).isEmpty ? '' : ' · ${item['resource_id']}'}'
            '${item['after_revision'] == null || item['after_revision'] == 0 ? '' : ' · r${item['after_revision']}'}'
            '${str(item['error_code']).isEmpty ? '' : ' · ${item['error_code']}'}').join('\n')}';
    if ((message['author'] as Map?)?['kind'] != 'agent' ||
        run == null ||
        run['action_plan'] is! Map ||
        result['content'] != content ||
        summaries.isEmpty ||
        !content.endsWith(appendix)) {
      return _selectable(content);
    }
    final receipts = maps(run['action_receipts']);
    final verified =
        summaries.map((item) => item['operation_id']).toSet().length ==
            summaries.length &&
        summaries.every(
          (summary) =>
              str(summary['operation_id']).isNotEmpty &&
              receipts.any(
                (receipt) =>
                    receipt['turn_id'] == turnId &&
                    receipt['principal_id'] == authorId &&
                    [
                      'committed',
                      'rejected',
                      'applying',
                    ].contains(receipt['status']) &&
                    [
                      'operation_id',
                      'operation',
                      'status',
                      'resource_id',
                      'after_revision',
                      'error_code',
                    ].every((key) => receipt[key] == summary[key]),
              ),
        );
    final committed = summaries
        .where((summary) => summary['status'] == 'committed')
        .length;
    final pending = summaries
        .where((summary) => summary['status'] == 'applying')
        .length;
    final rejected = summaries
        .where((summary) => summary['status'] == 'rejected')
        .length;
    final label = verified
        ? [
            if (committed > 0) '已提交 $committed 个动作',
            if (pending > 0) '$pending 个提交待确认',
            if (rejected > 0) '$rejected 个被拒绝',
          ].join(' · ')
        : '执行明细';
    final body = content.substring(0, content.length - appendix.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (body.isNotEmpty) _selectable(body),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: mutedColor, height: 1.6),
        ),
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () => widget.onRecords(turnId),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.receipt_long_outlined, size: 14),
              label: const Text('查看工作记录', style: TextStyle(fontSize: 11)),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
              ),
              label: Text(
                _expanded ? '收起执行原文' : '执行原文',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        if (_expanded)
          OfficeEmojiText(
            content: appendix.trimLeft(),
            selectable: widget.selectable,
            onAction: widget.onAction,
            onOpenMessageMenu: widget.onOpenMessageMenu,
            style: const TextStyle(
              fontSize: 10,
              height: 1.6,
              color: mutedColor,
            ),
          ),
      ],
    );
  }
}
