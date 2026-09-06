import 'dart:convert';

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart' show friendlyError;
import 'office_emoji.dart';
import 'office_theme.dart';

Future<Json?> showOfficeMessageTask(
  BuildContext context,
  OfficeState state,
  String roomId,
  List<Json> messages,
) => _showMessageWork(context, state, roomId, messages, false);

/// Returns the actual document only when the successful panel is closed.
Future<Json?> showOfficeMessageExport(
  BuildContext context,
  OfficeState state,
  String roomId,
  List<Json> messages,
) => _showMessageWork(context, state, roomId, messages, true);

// Keep uncertain creates across closing/reopening a panel in the same identity.
// Nothing is persisted or shared between OfficeState objects or identity epochs.
final _pendingWork = Expando<Map<String, Json>>('message-work-pending');

Future<Json?> _showMessageWork(
  BuildContext context,
  OfficeState state,
  String roomId,
  List<Json> messages,
  bool exportDocument,
) {
  final panel = OfficeMessageWorkPanel(
    state: state,
    roomId: roomId,
    messages: messages,
    exportDocument: exportDocument,
  );
  if (MediaQuery.sizeOf(context).width < 720) {
    return showModalBottomSheet<Json>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .9,
          child: panel,
        ),
      ),
    );
  }
  return showDialog<Json>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: 590,
        height: MediaQuery.sizeOf(context).height * .88,
        child: panel,
      ),
    ),
  );
}

class OfficeMessageWorkPanel extends StatefulWidget {
  const OfficeMessageWorkPanel({
    super.key,
    required this.state,
    required this.roomId,
    required this.messages,
    required this.exportDocument,
  });
  final OfficeState state;
  final String roomId;
  final List<Json> messages;
  final bool exportDocument;

  @override
  State<OfficeMessageWorkPanel> createState() => _OfficeMessageWorkPanelState();
}

class _OfficeMessageWorkPanelState extends State<OfficeMessageWorkPanel> {
  final _title = TextEditingController(), _body = TextEditingController();
  late final (OfficeState, int, String, String) _identity;
  late final String _roomId, _pendingKey;
  late final List<String> _messageIds;
  late final bool _export;
  List<Json> _sources = [], _people = [];
  String? _assignee, _error, _blocked, _successTitle;
  Json? _record, _pending;
  bool _expired = false, _busy = false, _ready = false, _edited = false;
  bool _uncertain = false, _needsReview = false;
  int _intent = 0;
  OfficeState get s => widget.state;
  (OfficeState, int, String, String) get _currentIdentity =>
      (s, s.identityGeneration, s.endpoint, personId(s.me ?? {}));
  bool get _current =>
      !_expired && s.me != null && _identity == _currentIdentity;
  bool get _canSave =>
      _current &&
      s.connected &&
      !_busy &&
      _ready &&
      !_needsReview &&
      _blocked == null &&
      _successTitle == null;

  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    _roomId = widget.roomId;
    _export = widget.exportDocument;
    final values = <String, Json>{};
    for (final message in widget.messages) {
      final value = Json.from(jsonDecode(jsonEncode(message)) as Map);
      values[str(value['id'])] = value;
    }
    _messageIds = List.unmodifiable(values.keys);
    _pendingKey = jsonEncode([
      _identity.$2,
      _identity.$3,
      _identity.$4,
      _roomId,
      _export,
      _messageIds,
    ]);
    _sources = values.values.toList();
    if (_roomId.isEmpty ||
        _messageIds.isEmpty ||
        _messageIds.contains('') ||
        _messageIds.length > 50) {
      _blocked = '请选择 1–50 条来源消息后重新打开。';
      _sources = [];
    } else if (_restriction(_sources) case final reason?) {
      _blocked = reason;
      _sources = [];
    } else {
      _prefill();
      _pending = _pendingWork[s]?[_pendingKey];
      if (_pending != null) {
        _uncertain = _edited = true;
        _title.text = str(_pending!['title']);
        _body.text = str(_pending![_export ? 'content' : 'description']);
        _assignee = _pending!['assignee_id'] as String?;
      }
    }
    s.addListener(_changed);
    if (_blocked == null) _checkSources();
  }

  @override
  void didUpdateWidget(covariant OfficeMessageWorkPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.messages.map((m) => str(m['id'])).toSet().toList();
    if (!identical(oldWidget.state, widget.state) ||
        widget.roomId != _roomId ||
        widget.exportDocument != _export ||
        jsonEncode(ids) != jsonEncode(_messageIds)) {
      _expire();
    } else if (_restriction(widget.messages) case final reason?) {
      _deny(reason);
    }
  }

  @override
  void dispose() {
    _intent++;
    _identity.$1.removeListener(_changed);
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _expire() {
    _expired = true;
    _intent++;
    _title.clear();
    _body.clear();
    _sources = [];
    _people = [];
    _assignee = _error = _successTitle = null;
    _record = _pending = null;
    _busy = false;
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) {
      setState(_expire);
      return;
    }
    if (str((s.detail?['room'] as Map?)?['id']) == _roomId) {
      final currentSources = maps(s.detail?['messages'])
          .where((m) => _messageIds.contains(str(m['id'])))
          .toList();
      final reason = _restriction(currentSources);
      if (reason != null) _deny(reason);
    }
    setState(() {});
  }

  String? _restriction(List<Json> sources) {
    for (final message in sources) {
      if (message['retracted_at'] != null) {
        return '来源消息已撤回，不能继续创建。请关闭后重新选择。';
      }
      if (message['hidden'] == true) {
        return '来源消息已隐藏，不能继续创建。请关闭后重新选择。';
      }
      if (message['no_forward'] == true) {
        return '来源消息禁止转发，不能复制到任务或文档。';
      }
      if (message['room_id'] != null && str(message['room_id']) != _roomId) {
        return '来源消息不属于当前来源会话，请重新选择。';
      }
    }
    return null;
  }

  void _deny(String reason) {
    _blocked = reason;
    _ready = false;
    _sources = [];
    _title.clear();
    _body.clear();
    _record = null;
    _successTitle = null;
  }

  String _signature(List<Json> sources) => jsonEncode([
    for (final message in sources)
      [
        message['id'],
        message['revision'],
        message['content'],
        message['at'],
        message['author_id'],
        message['author'],
        message['attachments'],
      ],
  ]);

  void _prefill() {
    final first = _sources.isEmpty ? '' : str(_sources.first['content']).trim();
    final line = first.split('\n').first;
    _title.text = _sources.length > 1
        ? '${_export ? '聊天记录' : '跟进消息'} · ${_sources.length} 条'
        : line.isEmpty
        ? (_export ? '聊天记录' : '消息待办')
        : line.characters.take(80).toString();
    _body.text = '';
  }

  Future<(List<Json>, List<Json>)> _readSources() async {
    final roomPath = '/rooms/${Uri.encodeComponent(_roomId)}';
    final results = await Future.wait([
      s.officeRequest(roomPath),
      for (final id in _messageIds)
        s.officeRequest('$roomPath/messages/${Uri.encodeComponent(id)}'),
    ]);
    final room = results.first['room'];
    if (room is! Map || str(room['id']) != _roomId) {
      throw const FormatException('来源会话校验失败');
    }
    final messages = <Json>[];
    for (var index = 0; index < _messageIds.length; index++) {
      final message = results[index + 1]['message'];
      if (message is! Map || str(message['id']) != _messageIds[index]) {
        throw const FormatException('来源消息校验失败');
      }
      messages.add(Json.from(message));
    }
    final members = <String, Json>{};
    for (final member in maps(results.first['members'])) {
      if (personId(member).isNotEmpty) {
        members[personId(member)] = member;
      }
    }
    return (messages, members.values.toList());
  }

  Future<bool> _resolvePending() async {
    if (!_uncertain || _pending == null) return false;
    final path = '/rooms/${Uri.encodeComponent(_roomId)}';
    final operation = _export ? 'export-document' : 'create-task';
    final clientId = str(_pending!['client_id']);
    final result = await s.officeRequest(
      '$path/messages/source-operations?client_id=${Uri.encodeComponent(clientId)}&operation=$operation',
    );
    if (!mounted || !_current) return true;
    final operations = maps(result['operations'])
        .where(
          (item) =>
              item['client_id'] == clientId &&
              item['operation'] == operation &&
              item['room_id'] == _roomId,
        )
        .toList();
    if (operations.isEmpty) return false;
    final previous = operations.first;
    if (previous['status'] != 'completed' ||
        str(previous['resource_id']).isEmpty) {
      setState(() => _error = '上次创建仍待确认，已保留请求。请稍后重试确认或查看来源会话，不能重复创建。');
      return true;
    }
    final id = str(previous['resource_id']);
    final response = await s.officeRequest(
      _export ? '$path/documents/${Uri.encodeComponent(id)}' : path,
    );
    if (!mounted || !_current) return true;
    final record = _export
        ? response['document']
        : maps(response['tasks']).where((task) => task['id'] == id).firstOrNull;
    if (record is! Map || str(record['id']) != id) {
      throw OfficeException(409, '上次创建已完成，但暂时无法读取结果。请重试确认，不要重复创建。');
    }
    _pendingWork[s]?.remove(_pendingKey);
    setState(() {
      _record = Json.from(record);
      _successTitle = str(record['title'], str(_pending!['title']));
      _pending = null;
      _uncertain = false;
    });
    return true;
  }

  Future<void> _checkSources({bool submit = false}) async {
    if (!_current ||
        _busy ||
        !s.connected ||
        _blocked != null ||
        _successTitle != null) {
      return;
    }
    if (submit && _title.text.trim().isEmpty) {
      setState(() => _error = '请填写${_export ? '文档' : '任务'}标题');
      return;
    }
    final intent = ++_intent;
    var posted = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (submit && _uncertain && await _resolvePending()) return;
      if (!mounted || !_current || intent != _intent) return;
      final fresh = await _readSources();
      if (!mounted || !_current || intent != _intent || _blocked != null) {
        return;
      }
      if (_restriction(fresh.$1) case final reason?) {
        setState(() => _deny(reason));
        return;
      }
      final changed = _signature(_sources) != _signature(fresh.$1);
      final wasReady = _ready;
      setState(() {
        _sources = fresh.$1;
        _people = fresh.$2;
        _ready = true;
        if (!wasReady && !_edited) _prefill();
      });
      if (submit && changed && !_uncertain) {
        setState(() => _error = '来源消息已更新。已刷新预览并保留草稿，请核对后再次提交。');
        return;
      }
      if (!submit) {
        if (_needsReview) {
          setState(() {
            _needsReview = false;
            _error = '已重新核对来源并保留补充说明，请检查后再次提交。';
          });
        }
        return;
      }
      if (!_uncertain &&
          _assignee != null &&
          !_people.any((p) => personId(p) == _assignee)) {
        setState(() {
          _assignee = null;
          _error = '原负责人已不在来源会话，请重新选择负责人后提交。';
        });
        return;
      }
      final title = _title.text.trim();
      final content = _body.text;
      if (title.length > 200) {
        setState(() => _error = '标题最多 200 个字符，请缩短后提交。');
        return;
      }
      if (!_current || !s.connected || _blocked != null) return;
      final payload =
          _pending ??
          {
            'client_id': OfficeState.newClientId(),
            'message_ids': _messageIds,
            'base_revisions': {
              for (final source in _sources)
                str(source['id']): source['revision'] ?? 1,
            },
            'title': title,
            _export ? 'content' : 'description': content,
            if (!_export) 'assignee_id': _assignee,
          };
      _pending = payload;
      (_pendingWork[s] ??= {})[_pendingKey] = payload;
      posted = true;
      final response = await s.officeRequest(
        '/rooms/${Uri.encodeComponent(_roomId)}/messages/${_export ? 'export-document' : 'create-task'}',
        method: 'POST',
        data: payload,
      );
      if (!mounted || !_current || intent != _intent || _blocked != null) {
        return;
      }
      final record = response[_export ? 'document' : 'task'];
      if (record is! Map || str(record['id']).isEmpty) {
        throw const FormatException('创建返回缺少记录，请重试确认同一次请求');
      }
      _pendingWork[s]?.remove(_pendingKey);
      setState(() {
        _successTitle = str(record['title'], title);
        _record = Json.from(record);
        _pending = null;
        _uncertain = false;
      });
    } catch (error) {
      if (mounted && _current && intent == _intent && _blocked == null) {
        setState(() {
          _error = friendlyError(error);
          if (_pending != null && posted) {
            final definitive =
                error is OfficeException &&
                error.status >= 400 &&
                error.status < 500;
            if (definitive && error.code != 'idempotency_conflict') {
              _pendingWork[s]?.remove(_pendingKey);
              _pending = null;
              _uncertain = false;
              if (error.status == 409) _needsReview = true;
            } else {
              _uncertain = true;
              if (error is OfficeException &&
                  error.code == 'idempotency_conflict') {
                _error = '创建请求标识与已保存的请求冲突。已保留原请求，请核对来源操作记录，不能另建请求绕过。';
              }
            }
          }
        });
      }
    } finally {
      if (mounted && intent == _intent) setState(() => _busy = false);
    }
  }

  void _close() {
    Navigator.of(context).pop(_current ? _record : null);
  }

  @override
  Widget build(BuildContext context) {
    final editable =
        _current &&
        !_busy &&
        !_uncertain &&
        _blocked == null &&
        _successTitle == null;
    final action = _export ? '导出到文档' : '添加任务';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  action,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('message-work-close'),
                tooltip: '关闭',
                onPressed: _close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: !_current
                ? const Text('工作身份或消息来源已变化，请关闭后重新打开。')
                : _blocked != null
                ? Text(
                    _blocked!,
                    style: const TextStyle(color: Colors.redAccent),
                  )
                : _successTitle != null
                ? Column(
                    children: [
                      const Icon(
                        Icons.check_circle_outline,
                        color: accentColor,
                        size: 42,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _export ? '文档已创建' : '任务已创建',
                        style: const TextStyle(fontSize: 18),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _successTitle!,
                        key: const ValueKey('message-work-success-title'),
                      ),
                      const SizedBox(height: 8),
                      Text(_export ? '已保存到来源会话的共享文档。' : '已保存到来源会话的任务列表。'),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '来自 ${_messageIds.length} 条消息',
                        style: const TextStyle(color: mutedColor),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 175),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final message in _sources)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${str((message['author'] as Map?)?['name'] ?? message['author_id'])} · ${clockText(message['at'], date: true, context: context)}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: mutedColor,
                                      ),
                                    ),
                                    OfficeEmojiText(
                                      content: str(message['content']),
                                      selectable: false,
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('message-work-title'),
                        controller: _title,
                        enabled: editable,
                        maxLength: 200,
                        onChanged: (_) => _edited = true,
                        decoration: InputDecoration(
                          labelText: _export ? '文档标题' : '任务标题',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('message-work-body'),
                        controller: _body,
                        enabled: editable,
                        minLines: 4,
                        maxLines: 9,
                        onChanged: (_) => _edited = true,
                        decoration: const InputDecoration(
                          labelText: '补充说明',
                          hintText: '可选，写下背景、要求或后续行动',
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '创建时将保存来源消息及其作者、时间和引用，无需在补充说明中重复粘贴。',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                      if (!_export) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: ValueKey(
                            'message-work-assignee-${_assignee ?? 'none'}',
                          ),
                          initialValue: _assignee ?? '',
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '负责人'),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('待分配'),
                            ),
                            if (_assignee != null &&
                                !_people.any((p) => personId(p) == _assignee))
                              DropdownMenuItem(
                                value: _assignee,
                                child: const Text('原负责人 · 待重新核对'),
                              ),
                            for (final person in _people)
                              DropdownMenuItem(
                                value: personId(person),
                                child: Text(
                                  '${officeDisplayName(person)} · ${person['kind'] == 'agent' ? 'Agent' : '人类'}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: editable
                              ? (value) => setState(
                                  () => _assignee = value == '' ? null : value,
                                )
                              : null,
                        ),
                      ],
                      if (!s.connected)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text('当前离线，草稿已保留。连接恢复后可重新核对来源。'),
                        ),
                      if (_uncertain)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text('上次创建结果尚未确认。已保留同一次请求，重试确认后再继续，避免重复创建。'),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _error!,
                            key: const ValueKey('message-work-error'),
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      if (!_ready || _error != null)
                        TextButton(
                          onPressed: _current && !_busy && s.connected
                              ? () => _checkSources()
                              : null,
                          child: const Text('重新核对来源'),
                        ),
                    ],
                  ),
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _close,
                  child: Text(_successTitle == null ? '取消' : '关闭'),
                ),
                if (_successTitle == null && _current && _blocked == null) ...[
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const ValueKey('message-work-submit'),
                    onPressed: _canSave
                        ? () => _checkSources(submit: true)
                        : null,
                    child: Text(
                      _busy
                          ? '正在核对与保存…'
                          : _uncertain
                          ? '重试确认'
                          : _export
                          ? '创建文档'
                          : '创建任务',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
