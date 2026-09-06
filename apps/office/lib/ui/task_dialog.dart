import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart' show friendlyError;
import 'office_theme.dart';

/// Own controllers until the dialog route's exit transition has completed.
class OfficeTaskDialog extends StatefulWidget {
  const OfficeTaskDialog({
    super.key,
    required this.state,
    required this.roomId,
  });
  final OfficeState state;
  final String roomId;
  @override
  State<OfficeTaskDialog> createState() => _OfficeTaskDialogState();
}

class _OfficeTaskDialogState extends State<OfficeTaskDialog> {
  final _title = TextEditingController(),
      _description = TextEditingController();
  String? _assignee, _error;
  bool _busy = false;
  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = '请填写任务名称');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.createTask(
        _title.text.trim(),
        description: _description.text.trim(),
        assigneeId: _assignee,
        roomId: widget.roomId,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text(
        '新建任务',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _title,
                enabled: !_busy,
                autofocus: true,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: '任务名称',
                  hintText: '写下一个具体、可完成的行动',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _description,
                enabled: !_busy,
                minLines: 4,
                maxLines: 7,
                decoration: const InputDecoration(
                  labelText: '目标与验收条件',
                  hintText: '要交付什么，如何判断完成？',
                ),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: _assignee ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '负责人'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('待分配')),
                  ...officeRoomPeople(widget.state, widget.roomId).map(
                    (person) => DropdownMenuItem(
                      value: personId(person),
                      child: Text(
                        '${str(person['name'])}${person['kind'] == 'agent' ? ' · Agent' : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => _assignee = value == '' ? null : value,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
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
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '正在创建…' : '创建任务'),
        ),
      ],
    ),
  );
}
