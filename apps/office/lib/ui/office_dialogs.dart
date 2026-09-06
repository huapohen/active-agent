import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'agent_action_plan.dart';
import 'agent_autonomy.dart';
import 'office_theme.dart';
import 'task_dialog.dart';
import 'room_nickname.dart';
import 'document_editor_launcher.dart';

String friendlyError(Object error) => error
    .toString()
    .replaceFirst('OfficeException: ', '')
    .replaceFirst('Exception: ', '');

class _OfficeMembers extends StatefulWidget {
  const _OfficeMembers({required this.state, required this.roomId});
  final OfficeState state;
  final String roomId;
  @override
  State<_OfficeMembers> createState() => _OfficeMembersState();
}

class _OfficeMembersState extends State<_OfficeMembers> {
  late final String _identity;
  Json? _detail;
  bool _expired = false, _busy = false, _loading = true;
  String? _error;
  String _query = '', _inviteQuery = '';
  int _generation = 0;
  String get _identityKey =>
      '${widget.state.endpoint}|${personId(widget.state.me ?? {})}|${widget.state.connected}';
  String get _path => '/rooms/${Uri.encodeComponent(widget.roomId)}';
  bool get _valid =>
      !_expired && widget.state.connected && _identityKey == _identity;
  List<Json> get _members => maps(_detail?['members']);
  Json get _room => Json.from(_detail?['room'] as Map? ?? {});
  String get _self => personId(widget.state.me ?? {});
  bool get _owner => _members.any(
    (member) => personId(member) == _self && member['role'] == 'owner',
  );
  bool get _group => _room['kind'] != 'direct';
  bool _removable(Json member) =>
      _valid &&
      _owner &&
      _group &&
      personId(member) != _self &&
      member['role'] != 'owner' &&
      personId(member) != _room['created_by'];
  bool _matches(Json member, String query) =>
      '${officeDisplayName(member)} ${str(member['name'])} ${personId(member)}'
          .toLowerCase()
          .contains(query.trim().toLowerCase());

  @override
  void initState() {
    super.initState();
    _identity = _identityKey;
    widget.state.addListener(_identityChanged);
    _read();
  }

  void _identityChanged() {
    if (!_valid && mounted) {
      setState(() {
        _expired = true;
        ++_generation;
        _detail = null;
      });
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_identityChanged);
    super.dispose();
  }

  Future<void> _read() async {
    if (!_valid) return;
    final generation = ++_generation;
    try {
      final result = await widget.state.officeRequest(_path);
      if (mounted && _valid && generation == _generation) {
        setState(() {
          _detail = result;
          _loading = false;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && _valid && generation == _generation) {
        setState(() {
          _error = friendlyError(error);
          _loading = false;
          if (error is OfficeException &&
              [401, 403, 404].contains(error.status)) {
            _detail = null;
          }
        });
      }
    }
  }

  Future<void> _remove(Json target) async {
    if (!_removable(target) || _busy) return;
    final pid = personId(target);
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AnimatedBuilder(
        animation: widget.state,
        builder: (_, _) => AlertDialog(
          title: const Text('移除群成员'),
          content: Text(
            _valid
                ? '将「${officeDisplayName(target)}」从「${str(_room['name'])}」移除？\n\n工作身份：${str(target['name'])}\n身份 ID：$pid\n\n对方将失去本群访问权限；正在推进的 Agent 工作会停止。'
                : '工作身份已变更，请关闭后重新打开成员管理。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _valid
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('确认移除'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || !_valid || approved != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Recheck the current role and target after the explicit confirmation.
      final latest = await widget.state.officeRequest(_path);
      if (!mounted || !_valid) return;
      setState(() => _detail = latest);
      final current = _members
          .where((member) => personId(member) == pid)
          .firstOrNull;
      if (current == null) throw OfficeException(404, '该成员已离开本群');
      if (!_removable(current)) throw OfficeException(403, '成员权限已变化，不能移除该成员');
      await widget.state.officeRequest(
        '$_path/members/${Uri.encodeComponent(pid)}',
        method: 'DELETE',
        data: {},
      );
      if (!mounted || !_valid) return;
      await _read();
      if (!mounted || !_valid) return;
      await widget.state.refresh();
    } catch (error) {
      if (mounted && _valid) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _invite(Json person) async {
    if (!_valid || !_owner || !_group || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.officeRequest(
        '$_path/members',
        method: 'POST',
        data: {'principal_id': personId(person)},
      );
      if (!mounted || !_valid) return;
      await _read();
      if (!mounted || !_valid) return;
      await widget.state.refresh();
    } catch (error) {
      if (mounted && _valid) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _nickname() async {
    if (!_valid) return;
    final saved = await showOfficeRoomNickname(
      context,
      widget.state,
      roomId: widget.roomId,
    );
    if (!mounted || !_valid || saved != true) return;
    await _read();
    if (!mounted || !_valid) return;
    try {
      await widget.state.refresh();
    } catch (error) {
      if (mounted && _valid) setState(() => _error = friendlyError(error));
    }
  }

  Future<void> _agent(Json member) async {
    if (!_valid) return;
    await showAgentAutonomy(
      context,
      widget.state,
      member,
      roomId: widget.roomId,
      canEdit: _owner || personId(member) == _self,
      roomRevision: (_room['revision'] as num?)?.toInt(),
    );
    if (mounted && _valid) await _read();
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.state.principals
        .where(
          (person) =>
              !_members.any((member) => personId(member) == personId(person)),
        )
        .toList();
    return AlertDialog(
      title: Text(_valid ? '会话成员 · ${_members.length}' : '会话成员'),
      content: SizedBox(
        width: 480,
        child: !_valid
            ? const Text('工作身份已变更，旧会话成员已隐藏。')
            : _loading
            ? const Center(heightFactor: 2, child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      str(_room['name']),
                      style: const TextStyle(fontSize: 12, color: mutedColor),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      decoration: const InputDecoration(
                        hintText: '搜索成员姓名、群昵称或 ID',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 10),
                    if (!_members.any((member) => _matches(member, _query)))
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('没有匹配的成员'),
                      ),
                    for (final member in _members.where(
                      (member) => _matches(member, _query),
                    ))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: PersonAvatar(
                          name: officeDisplayName(member),
                          agent: member['kind'] == 'agent',
                          size: 32,
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                officeDisplayName(member),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const SizedBox(width: 5),
                            IdentityBadge(agent: member['kind'] == 'agent'),
                          ],
                        ),
                        subtitle: Text(
                          '${member['role'] == 'owner' ? '会话负责人' : '工作成员'}${officeDisplayName(member) == str(member['name']) ? '' : ' · ${str(member['name'])}'}',
                          style: const TextStyle(fontSize: 10),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (member['kind'] == 'agent')
                              IconButton(
                                tooltip: '${str(member['name'])} · 人格与参与',
                                onPressed: _busy ? null : () => _agent(member),
                                icon: const Icon(Icons.tune, size: 18),
                              ),
                            if (_removable(member))
                              IconButton(
                                tooltip: '移除 ${str(member['name'])}',
                                onPressed: _busy ? null : () => _remove(member),
                                icon: const Icon(
                                  Icons.person_remove_outlined,
                                  size: 18,
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (_group &&
                        _members.any((member) => personId(member) == _self))
                      TextButton.icon(
                        onPressed: _busy ? null : _nickname,
                        icon: const Icon(Icons.badge_outlined, size: 17),
                        label: const Text('我在本群的昵称'),
                      ),
                    if (_owner && _group && available.isNotEmpty) ...[
                      const Divider(height: 26),
                      const Text(
                        '添加工作成员',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(
                          hintText: '搜索可添加的同事',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (value) =>
                            setState(() => _inviteQuery = value),
                      ),
                      for (final person in available.where(
                        (person) => _matches(person, _inviteQuery),
                      ))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: PersonAvatar(
                            name: str(person['name']),
                            agent: person['kind'] == 'agent',
                            size: 30,
                          ),
                          title: Text(
                            str(person['name']),
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: TextButton(
                            onPressed: _busy ? null : () => _invite(person),
                            child: const Text('添加'),
                          ),
                        ),
                    ],
                    BusinessError(_error),
                    if (_error != null)
                      TextButton(
                        onPressed: _busy ? null : _read,
                        child: const Text('刷新成员'),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        '人和 Agent 共享消息、文档与任务能力；群内昵称保留可辨认的工作身份。',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class OfficeDialogs {
  static final Map<String, Json> _documentDrafts = {};

  static Future<void> createRoom(
    BuildContext context,
    OfficeState state, {
    List<String> memberIds = const [],
  }) async {
    final title = TextEditingController(),
        description = TextEditingController();
    final members = memberIds.toSet()..remove(personId(state.me ?? {}));
    var busy = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _DialogControllerScope(
        controllers: [title, description],
        child: StatefulBuilder(
          builder: (context, change) => AlertDialog(
            title: const Text(
              '创建工作群',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: title,
                      autofocus: true,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: '群名称',
                        hintText: '例如：产品发布协作',
                      ),
                    ),
                    const SizedBox(height: 15),
                    TextField(
                      controller: description,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: '共同目标',
                        hintText: '写下这项工作的背景和目标',
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '邀请工作成员',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...state.principals
                        .where((p) => personId(p) != personId(state.me ?? {}))
                        .map(
                          (p) => CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: members.contains(personId(p)),
                            onChanged: (v) => change(() {
                              v == true
                                  ? members.add(personId(p))
                                  : members.remove(personId(p));
                            }),
                            title: Row(
                              children: [
                                PersonAvatar(
                                  name: str(p['name']),
                                  agent: p['kind'] == 'agent',
                                  size: 28,
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    str(p['name']),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                IdentityBadge(agent: p['kind'] == 'agent'),
                              ],
                            ),
                          ),
                        ),
                    if (error != null)
                      Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
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
                          change(() => error = '请填写群名称');
                          return;
                        }
                        change(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await state.createRoom(
                            title.text.trim(),
                            description: description.text.trim(),
                            memberIds: members.toList(),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            change(() {
                              error = friendlyError(e);
                              busy = false;
                            });
                          }
                        }
                      },
                child: Text(busy ? '正在创建…' : '创建工作群'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> members(
    BuildContext context,
    OfficeState state, {
    String? roomId,
  }) async {
    final target = roomId ?? state.selectedRoomId;
    if (target == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _OfficeMembers(state: state, roomId: target),
    );
  }

  static Future<void> task(
    BuildContext context,
    OfficeState state, {
    String? roomId,
  }) async {
    roomId ??= state.selectedRoomId ?? await chooseOfficeRoom(context, state);
    if (roomId == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => OfficeTaskDialog(state: state, roomId: roomId!),
    );
  }

  static Future<void> document(
    BuildContext context,
    OfficeState state, [
    Json? source,
  ]) async {
    final roomIds = (source?['room_ids'] as List? ?? []).map(str).toList();
    final roomId =
        source?['room_id'] as String? ??
        (roomIds.contains(state.selectedRoomId)
            ? state.selectedRoomId
            : roomIds.firstOrNull) ??
        state.selectedRoomId ??
        await chooseOfficeRoom(context, state);
    if (roomId == null || !context.mounted) return;
    if (source?['id'] != null && source?['content'] == null) {
      source = await state.getDocument(str(source!['id']), roomId: roomId);
      if (!context.mounted) return;
    }
    final draftKey =
        '${state.endpoint}:${personId(state.me ?? {})}:$roomId:${source?['id'] ?? 'new'}';
    final draft = _documentDrafts[draftKey];
    final title = TextEditingController(
      text: str(draft?['title'] ?? source?['title']),
    );
    final content = TextEditingController(
      text: str(draft?['content'] ?? source?['content']),
    );
    String? id = source?['id'];
    int? revision = draft?['revision'] ?? source?['revision'];
    String? error;
    var busy = false, saved = false, mergeAvailable = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _DialogControllerScope(
        controllers: [title, content],
        child: StatefulBuilder(
          builder: (context, change) => Dialog(
            insetPadding: const EdgeInsets.all(18),
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 850,
                maxHeight: MediaQuery.sizeOf(context).height * .87,
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.description_outlined,
                          color: accentColor,
                          size: 18,
                        ),
                        const SizedBox(width: 9),
                        const Text(
                          '共同文档',
                          style: TextStyle(fontSize: 12, color: mutedColor),
                        ),
                        const Spacer(),
                        Text(
                          revision == null ? '新建文档' : '共同版本 r$revision',
                          style: const TextStyle(
                            fontSize: 11,
                            color: mutedColor,
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          tooltip: '关闭文档',
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    TextField(
                      controller: title,
                      maxLength: 200,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: const InputDecoration(
                        hintText: '给这份文档起个名字',
                        filled: false,
                        counterText: '',
                        border: InputBorder.none,
                      ),
                      onChanged: (_) => saved = false,
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 11),
                      child: Text(
                        '人和 Agent 读取同一份内容。保存后，所有会话成员可继续共同编辑。',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: TextField(
                        controller: content,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(fontSize: 13, height: 1.9),
                        decoration: const InputDecoration(
                          hintText: '# 共同目标\n\n写下背景、依据和行动计划…',
                          filled: false,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 18),
                        ),
                        onChanged: (_) => saved = false,
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Text(
                          error!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 9,
                      runSpacing: 9,
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: content.text),
                            );
                            if (context.mounted) {
                              notifyOffice(context, '文档原文已复制');
                            }
                          },
                          icon: const Icon(Icons.copy_outlined, size: 15),
                          label: const Text('复制 Markdown'),
                        ),
                        if (id != null)
                          TextButton.icon(
                            onPressed: busy
                                ? null
                                : () async {
                                    change(() {
                                      busy = true;
                                      error = null;
                                      mergeAvailable = false;
                                    });
                                    try {
                                      await openOfficeDocumentEditor(
                                        () => state.documentEditorUrl(
                                          id!,
                                          roomId: roomId,
                                        ),
                                      );
                                    } catch (e) {
                                      if (dialogContext.mounted) {
                                        change(() => error = friendlyError(e));
                                      }
                                    } finally {
                                      if (dialogContext.mounted) {
                                        change(() => busy = false);
                                      }
                                    }
                                  },
                            icon: const Icon(Icons.edit_document, size: 15),
                            label: const Text('协作编辑器'),
                          ),
                        if (mergeAvailable && error != null && id != null)
                          TextButton(
                            onPressed: () async {
                              try {
                                final latest = await state.getDocument(
                                  id!,
                                  roomId: roomId,
                                );
                                if (!dialogContext.mounted) return;
                                change(() {
                                  revision = latest['revision'];
                                  content.text =
                                      '<!-- 你的未合并草稿 -->\n${content.text}\n\n<!-- 共同文档最新版本 r$revision -->\n${str(latest['content'])}';
                                  error = '已保留草稿与最新版本。请合并内容、移除分隔说明后保存。';
                                });
                              } catch (e) {
                                change(() => error = friendlyError(e));
                              }
                            },
                            child: const Text('读取最新版本并合并'),
                          ),
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  if (title.text.trim().isEmpty ||
                                      content.text.trim().isEmpty) {
                                    change(() => error = '请填写标题与正文');
                                    return;
                                  }
                                  change(() {
                                    busy = true;
                                    error = null;
                                    mergeAvailable = false;
                                  });
                                  try {
                                    final result = await state.saveDocument(
                                      id: id,
                                      title: title.text.trim(),
                                      content: content.text,
                                      baseRevision: revision,
                                      roomId: roomId,
                                    );
                                    if (!dialogContext.mounted) return;
                                    change(() {
                                      id = result['id'];
                                      revision = result['revision'];
                                      busy = false;
                                      saved = true;
                                    });
                                    _documentDrafts.remove(draftKey);
                                    notifyOffice(context, '共同文档已保存');
                                  } catch (e) {
                                    if (dialogContext.mounted) {
                                      change(() {
                                        error = friendlyError(e);
                                        busy = false;
                                        mergeAvailable =
                                            e is OfficeException &&
                                            e.status == 409;
                                      });
                                    }
                                  }
                                },
                          child: Text(busy ? '正在保存…' : '保存共同文档'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!saved && (title.text.isNotEmpty || content.text.isNotEmpty)) {
      _documentDrafts[draftKey] = {
        'title': title.text,
        'content': content.text,
        'revision': revision,
      };
    }
  }

  static Future<void> run(
    BuildContext context,
    OfficeState state,
    String id,
  ) async {
    final parentContext = context;
    var future = state.getRun(id);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, change) => Dialog(
          insetPadding: const EdgeInsets.all(18),
          backgroundColor: Colors.white,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 820,
              maxHeight: MediaQuery.sizeOf(context).height * .87,
            ),
            child: FutureBuilder<Json>(
              future: future,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return Padding(
                    padding: const EdgeInsets.all(50),
                    child: snapshot.hasError
                        ? Text(friendlyError(snapshot.error!))
                        : const Center(child: CircularProgressIndicator()),
                  );
                }
                final run = snapshot.data!;
                final result = run['result'] is Map
                    ? Map<String, dynamic>.from(run['result'])
                    : <String, dynamic>{};
                final artifact = result['artifact'] is Map
                    ? Map<String, dynamic>.from(result['artifact'])
                    : null;
                final evidence = run['context'] ?? {};
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '工作记录与共同依据',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '刷新行动与回执',
                            onPressed: () =>
                                change(() => future = state.getRun(id)),
                            icon: const Icon(Icons.refresh, size: 18),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ),
                      Text(
                        '${statusName(run['status'])} · ${clockText(run['created_at'], date: true, context: context)}',
                        style: const TextStyle(fontSize: 11, color: mutedColor),
                      ),
                      const SizedBox(height: 18),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AgentActionPlan(run: run),
                              if (artifact != null) ...[
                                Text(
                                  str(artifact['title']),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 13),
                                SelectableText(
                                  str(artifact['content']),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.85,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                FilledButton.icon(
                                  onPressed: () async {
                                    try {
                                      final doc = await state.saveArtifact(id);
                                      if (dialogContext.mounted) {
                                        Navigator.pop(dialogContext);
                                        if (parentContext.mounted) {
                                          await document(
                                            parentContext,
                                            state,
                                            doc,
                                          );
                                        }
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        notifyOffice(context, friendlyError(e));
                                      }
                                    }
                                  },
                                  icon: const Icon(
                                    Icons.note_add_outlined,
                                    size: 17,
                                  ),
                                  label: const Text('保存为共同文档'),
                                ),
                                const Divider(height: 36),
                              ],
                              if (result['rationale'] != null) ...[
                                const Text(
                                  '判断与说明',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 9),
                                SelectableText(
                                  str(result['rationale']),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.8,
                                  ),
                                ),
                                const SizedBox(height: 25),
                              ],
                              const Text(
                                '完整依据快照',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                '本次读取的讨论、文档版本、任务与省略范围都保留在这里。',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: mutedColor,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(0xfff7f8fa),
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: SelectableText(
                                  const JsonEncoder.withIndent('  ')
                                      .convert(evidence),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    height: 1.8,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  static Future<String?> editText(
    BuildContext context,
    String value, {
    String title = '编辑消息',
  }) async {
    final controller = TextEditingController(text: value);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _DialogControllerScope(
        controllers: [controller],
        child: AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 18)),
          content: SizedBox(
            width: 450,
            child: TextField(
              controller: controller,
              minLines: 3,
              maxLines: 10,
              autofocus: true,
              decoration: const InputDecoration(hintText: '消息内容'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  static Future<void> export(BuildContext context, OfficeState state) async {
    try {
      final text = await state.exportRoom();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导出工作记录', style: TextStyle(fontSize: 18)),
          content: SizedBox(
            width: 650,
            height: 420,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontSize: 11, height: 1.8),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) notifyOffice(context, '完整工作记录已复制');
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制 Markdown'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) notifyOffice(context, friendlyError(e));
    }
  }
}

/// Dialog futures resolve on pop, before the reverse transition is finished.
/// Keep editing controllers alive until the route's subtree is actually removed.
class _DialogControllerScope extends StatefulWidget {
  const _DialogControllerScope({
    required this.controllers,
    required this.child,
  });
  final List<TextEditingController> controllers;
  final Widget child;
  @override
  State<_DialogControllerScope> createState() => _DialogControllerScopeState();
}

class _DialogControllerScopeState extends State<_DialogControllerScope> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
